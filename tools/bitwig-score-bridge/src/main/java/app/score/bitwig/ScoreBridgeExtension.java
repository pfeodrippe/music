package app.score.bitwig;

import java.io.BufferedWriter;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.net.SocketException;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.DatagramChannel;
import java.net.StandardProtocolFamily;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import clojure.java.api.Clojure;
import clojure.lang.IFn;

import com.bitwig.extension.controller.ControllerExtension;
import com.bitwig.extension.controller.api.Application;
import com.bitwig.extension.controller.api.ControllerHost;
import com.bitwig.extension.controller.api.CursorTrack;
import com.bitwig.extension.controller.api.MidiIn;
import com.bitwig.extension.controller.api.NoteInput;
import com.bitwig.extension.controller.api.Transport;

public final class ScoreBridgeExtension extends ControllerExtension {
   private static final int OSC_PORT = 8000;
   private static final int CONTROLLER_SLOTS = 16;

   private final NoteInput[] noteInputs = new NoteInput[CONTROLLER_SLOTS];
   // Bitwig's OSC callback supplies a fresh opaque OscConnection per datagram,
   // so it cannot associate a note-off with the controller that sent the
   // note-on. Owning the UDP socket gives us the real sender address and keeps
   // simultaneous iPads/macOS instances in stable, independent slots.
   private final Map<SocketAddress, Integer> sourceSlots = new HashMap<>();
   private final int[][][] heldNotes = new int[CONTROLLER_SLOTS][16][128];
   private IFn decode;
   private IFn describe;
   private ControllerHost host;
   private CursorTrack targetTrack;
   private Transport transport;
   private Application application;
   private BufferedWriter probeLog;
   private DatagramChannel oscChannel;
   private DatagramSocket oscSocket;
   private Thread oscThread;
   private volatile boolean oscRunning;

   ScoreBridgeExtension(final ScoreBridgeExtensionDefinition definition, final ControllerHost host) {
      super(definition, host);
   }

   @Override
   public void init() {
      host = getHost();
      transport = host.createTransport();
      application = host.createApplication();
      targetTrack = host.createCursorTrack("score-osc-target", "Score OSC Target", 0, 0, true);

      // Bitwig runs each controller extension in its own class loader, while
      // Clojure resolves clojure/core.clj through the thread context loader.
      // Point that loader at this extension before Clojure's RT initializes;
      // otherwise a correctly shaded .bwextension still cannot see its own
      // runtime resources.
      final Thread thread = Thread.currentThread();
      final ClassLoader previousLoader = thread.getContextClassLoader();
      thread.setContextClassLoader(ScoreBridgeExtension.class.getClassLoader());
      try {
         final IFn require = Clojure.var("clojure.core", "require");
         require.invoke(Clojure.read("app.score.bitwig.protocol"));
         decode = Clojure.var("app.score.bitwig.protocol", "decode");
         describe = Clojure.var("app.score.bitwig.protocol", "describe");
      } finally {
         thread.setContextClassLoader(previousLoader);
      }

      final MidiIn midiIn = host.getMidiInPort(0);
      for (int slot = 0; slot < noteInputs.length; ++slot) {
         noteInputs[slot] = midiIn.createNoteInput("Score OSC " + (slot + 1), "000000");
         noteInputs[slot].includeInAllInputs().set(true);
         // A NoteInput by itself is only offered in Bitwig's input chooser.
         // Route each isolated controller slot to the selected track directly,
         // independent of the track's monitoring and input-filter settings.
         targetTrack.addNoteSource(noteInputs[slot]);
      }

      openProbeLog();
      startOscServer();
      log("READY port=" + OSC_PORT + " slots=" + CONTROLLER_SLOTS + " route=selected-track");
      host.showPopupNotification("Score OSC Bridge listening on UDP " + OSC_PORT);
   }

   private void startOscServer() {
      try {
         // Bitwig's embedded JVM may prefer an IPv6 wildcard for the
         // one-argument bind. Loopback Simulator traffic still reaches that
         // socket, but IPv4 datagrams from a physical iPad do not on macOS.
         // An INET DatagramChannel forces a true IPv4 socket; constructing a
         // DatagramSocket directly still becomes dual-stack IPv6 on that JVM.
         oscChannel = DatagramChannel.open(StandardProtocolFamily.INET);
         oscChannel.bind(new InetSocketAddress("0.0.0.0", OSC_PORT));
         oscSocket = oscChannel.socket();
      } catch (final IOException error) {
         throw new IllegalStateException("Cannot bind Score OSC UDP port " + OSC_PORT, error);
      }
      oscRunning = true;
      oscThread = new Thread(this::receiveOsc, "Score OSC UDP receiver");
      oscThread.setContextClassLoader(ScoreBridgeExtension.class.getClassLoader());
      oscThread.setDaemon(true);
      oscThread.start();
   }

   private void receiveOsc() {
      final byte[] bytes = new byte[2048];
      while (oscRunning) {
         final DatagramPacket packet = new DatagramPacket(bytes, bytes.length);
         try {
            oscSocket.receive(packet);
            final ParsedOsc parsed = parseOsc(packet.getData(), packet.getOffset(), packet.getLength());
            if (parsed == null) continue;
            final SocketAddress source = packet.getSocketAddress();
            host.scheduleTask(() -> onOsc(source, parsed.address(), parsed.arguments()), 0);
         } catch (final SocketException error) {
            if (oscRunning) host.scheduleTask(() -> log("OSC SOCKET ERROR " + error.getMessage()), 0);
            return;
         } catch (final IOException | RuntimeException error) {
            host.scheduleTask(() -> log("OSC PACKET ERROR " + error.getMessage()), 0);
         }
      }
   }

   private static ParsedOsc parseOsc(final byte[] bytes, final int offset, final int length) {
      final int limit = offset + length;
      final ParsedString address = parseOscString(bytes, offset, limit);
      if (address == null || address.value().isEmpty() || address.value().charAt(0) != '/') return null;
      final ParsedString types = parseOscString(bytes, address.next(), limit);
      if (types == null || types.value().isEmpty() || types.value().charAt(0) != ',') return null;
      int cursor = types.next();
      final List<Object> arguments = new ArrayList<>();
      for (int index = 1; index < types.value().length(); ++index) {
         final char type = types.value().charAt(index);
         if (type == 'i') {
            if (cursor + 4 > limit) return null;
            arguments.add(ByteBuffer.wrap(bytes, cursor, 4).order(ByteOrder.BIG_ENDIAN).getInt());
            cursor += 4;
         } else if (type == 'T') {
            arguments.add(Boolean.TRUE);
         } else if (type == 'F') {
            arguments.add(Boolean.FALSE);
         } else {
            return null;
         }
      }
      return new ParsedOsc(address.value(), List.copyOf(arguments));
   }

   private static ParsedString parseOscString(final byte[] bytes, final int offset, final int limit) {
      int end = offset;
      while (end < limit && bytes[end] != 0) ++end;
      if (end >= limit) return null;
      final String value = new String(bytes, offset, end - offset, StandardCharsets.UTF_8);
      final int next = (end + 4) & ~3;
      return next <= limit ? new ParsedString(value, next) : null;
   }

   private record ParsedString(String value, int next) { }
   private record ParsedOsc(String address, List<Object> arguments) { }

   private void onOsc(final SocketAddress source, final String address, final List<Object> arguments) {
      Integer slotValue = sourceSlots.get(source);
      if (slotValue == null) {
         final int allocated = allocateSlot();
         if (allocated < 0) {
            log("REJECT source=" + source + " reason=all-controller-slots-in-use");
            return;
         }
         sourceSlots.put(source, allocated);
         slotValue = allocated;
      }
      final int slot = slotValue;
      final Object decoded = decode.invoke(address, arguments);
      log("RX slot=" + (slot + 1) + " source=" + source + " " + describe.invoke(address, arguments));
      if (!(decoded instanceof Object[] event) || event.length < 4) return;

      final String kind = String.valueOf(event[0]);
      final int channel = clamp(number(event[1]), 0, 15);
      final int number = clamp(number(event[2]), 0, 127);
      final int value = clamp(number(event[3]), 0, 127);
      dispatch(slot, kind, channel, number, value);
   }

   private int allocateSlot() {
      final boolean[] used = new boolean[noteInputs.length];
      for (final int slot : sourceSlots.values()) used[slot] = true;
      for (int slot = 0; slot < used.length; ++slot) if (!used[slot]) return slot;
      // Never alias two sources onto one NoteInput: explicit rejection is
      // safer than cross-controller note-off/pressure interference.
      return -1;
   }

   private void dispatch(final int slot, final String kind, final int channel, final int number, final int value) {
      switch (kind) {
         case "note", "drum" -> sendNote(slot, channel, number, value);
         case "cc" -> noteInputs[slot].sendRawMidiEvent(0xB0 | channel, number, value);
         case "aftertouch" -> noteInputs[slot].sendRawMidiEvent(0xA0 | channel, number, value);
         case "stop" -> transport.stop();
         case "play" -> { if (value != 0) transport.togglePlay(); }
         case "record" -> transport.record();
         case "loop" -> { if (value != 0) transport.toggleLoop(); }
         case "click" -> { if (value != 0) transport.toggleClick(); }
         case "undo" -> application.undo();
         case "redo" -> application.redo();
         case "refresh" -> host.showPopupNotification("Score controller connected on slot " + (slot + 1));
         default -> log("UNHANDLED kind=" + kind + " number=" + number + " value=" + value);
      }
   }

   private void sendNote(final int slot, final int channel, final int note, final int velocity) {
      final int status = 0x90 | channel;
      if (velocity > 0) {
         heldNotes[slot][channel][note] += 1;
         noteInputs[slot].sendRawMidiEvent(status, note, velocity);
      } else if (heldNotes[slot][channel][note] > 0) {
         heldNotes[slot][channel][note] -= 1;
         if (heldNotes[slot][channel][note] == 0) noteInputs[slot].sendRawMidiEvent(status, note, 0);
      }
   }

   private static int number(final Object value) {
      return value instanceof Number number ? number.intValue() : 0;
   }

   private static int clamp(final int value, final int minimum, final int maximum) {
      return Math.max(minimum, Math.min(maximum, value));
   }

   private void openProbeLog() {
      try {
         final Path directory = Path.of(System.getProperty("user.home"), "Library", "Application Support", "Score");
         Files.createDirectories(directory);
         probeLog = Files.newBufferedWriter(directory.resolve("bitwig-score-bridge.log"), StandardCharsets.UTF_8,
            StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE);
      } catch (final IOException error) {
         host.println("Score bridge probe log unavailable: " + error.getMessage());
      }
   }

   private void log(final String message) {
      final String line = Instant.now() + " " + message;
      host.println("[ScoreBridge] " + line);
      if (probeLog == null) return;
      try {
         probeLog.write(line);
         probeLog.newLine();
         probeLog.flush();
      } catch (final IOException error) {
         host.println("Score bridge probe write failed: " + error.getMessage());
      }
   }

   @Override public void flush() { }

   @Override
   public void exit() {
      oscRunning = false;
      if (oscSocket != null) oscSocket.close();
      for (int slot = 0; slot < heldNotes.length; ++slot) {
         for (int channel = 0; channel < heldNotes[slot].length; ++channel) {
            for (int note = 0; note < heldNotes[slot][channel].length; ++note) {
               if (heldNotes[slot][channel][note] > 0) {
                  noteInputs[slot].sendRawMidiEvent(0x90 | channel, note, 0);
               }
            }
         }
      }
      if (probeLog != null) {
         try { probeLog.close(); }
         catch (final IOException ignored) { }
      }
      if (oscThread != null) {
         try { oscThread.join(500); }
         catch (final InterruptedException error) { Thread.currentThread().interrupt(); }
      }
   }
}
