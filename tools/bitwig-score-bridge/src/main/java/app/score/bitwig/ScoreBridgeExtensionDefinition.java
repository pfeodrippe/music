package app.score.bitwig;

import java.util.UUID;

import com.bitwig.extension.api.PlatformType;
import com.bitwig.extension.controller.AutoDetectionMidiPortNamesList;
import com.bitwig.extension.controller.ControllerExtensionDefinition;
import com.bitwig.extension.controller.api.ControllerHost;

public final class ScoreBridgeExtensionDefinition extends ControllerExtensionDefinition {
   private static final UUID ID = UUID.fromString("e8435ec3-20f3-49c7-8f7d-13e9fa759ca8");

   @Override public String getName() { return "Score OSC Bridge + Probe"; }
   @Override public String getAuthor() { return "Score"; }
   @Override public String getVersion() { return "0.1.0"; }
   @Override public UUID getId() { return ID; }
   @Override public String getHardwareVendor() { return "Score"; }
   @Override public String getHardwareModel() { return "OSC Bridge"; }
   @Override public int getRequiredAPIVersion() { return 22; }
   @Override public int getNumMidiInPorts() { return 1; }
   @Override public int getNumMidiOutPorts() { return 0; }

   @Override
   public void listAutoDetectionMidiPortNames(final AutoDetectionMidiPortNamesList list, final PlatformType platformType) {
      // The OSC clients themselves need no MIDI endpoint. During development a
      // deliberately named Score endpoint lets Bitwig auto-create this
      // extension without a brittle trip through its custom controller picker.
      // It remains only the owner of the NoteInput objects; every performer is
      // still separated by the OSC bridge below it.
      if (platformType == PlatformType.MAC) {
         list.add(new String[]{"Score Bridge Bootstrap"}, new String[]{});
      }
   }

   @Override
   public ScoreBridgeExtension createInstance(final ControllerHost host) {
      return new ScoreBridgeExtension(this, host);
   }
}
