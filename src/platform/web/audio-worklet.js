class ScoreAudioProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const wasmModule = options.processorOptions.wasmModule;
    this.instance = new WebAssembly.Instance(wasmModule, {});
    this.exports = this.instance.exports;
    this.memory = this.exports.memory;
    this.exports.score_audio_reset();
    this.outputChannels = this.exports.score_audio_channels();
    this.pitchCapacity = this.exports.score_pitch_input_capacity();
    this.pitchWindow = new Float32Array(this.pitchCapacity);
    this.pitchLength = 0;
    this.port.onmessage = ({data}) => {
      if (data.type === "midi") {
        this.exports.score_audio_midi(data.status, data.data1, data.data2);
      } else if (data.type === "all-notes-off") {
        this.exports.score_audio_all_notes_off();
      } else if (data.type === "click") {
        this.exports.score_audio_click(data.accent ? 1 : 0);
      } else if (data.type === "bank") {
        const bytes = new Uint8Array(data.bytes);
        const pointer = this.exports.score_audio_bank_allocate(bytes.byteLength);
        let status = 1;
        if (pointer) {
          new Uint8Array(this.memory.buffer, pointer, bytes.byteLength).set(bytes);
          status = this.exports.score_audio_bank_commit(bytes.byteLength);
        }
        this.port.postMessage({
          type: "bank-status",
          status,
          samples: status === 0 ? this.exports.score_audio_bank_samples() : 0,
          regions: status === 0 ? this.exports.score_audio_bank_regions() : 0
        });
      }
    };
  }

  analyzeInput(input) {
    if (!input || input.length === 0) return;
    let sourceOffset = 0;
    while (sourceOffset < input.length) {
      const count = Math.min(input.length - sourceOffset, this.pitchCapacity - this.pitchLength);
      this.pitchWindow.set(input.subarray(sourceOffset, sourceOffset + count), this.pitchLength);
      this.pitchLength += count;
      sourceOffset += count;
      if (this.pitchLength === this.pitchCapacity) {
        const pointer = this.exports.score_pitch_input_pointer();
        new Float32Array(this.memory.buffer, pointer, this.pitchCapacity).set(this.pitchWindow);
        const note = this.exports.score_pitch_analyze(this.pitchCapacity, sampleRate);
        if (note !== 255) this.port.postMessage({type:"pitch", note, confidence:this.exports.score_pitch_confidence()});
        this.pitchLength = 0;
      }
    }
  }

  process(inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;
    const frames = output[0].length;
    const pointer = this.exports.score_audio_render(frames, sampleRate);
    const interleaved = new Float32Array(this.memory.buffer, pointer, frames * this.outputChannels);
    for (let channelIndex = 0; channelIndex < output.length; channelIndex += 1) {
      const channel = output[channelIndex];
      const sourceChannel = Math.min(channelIndex, this.outputChannels - 1);
      for (let frame = 0; frame < frames; frame += 1) channel[frame] = interleaved[frame * this.outputChannels + sourceChannel];
    }
    this.analyzeInput(inputs[0]?.[0]);
    return true;
  }
}

registerProcessor("score-audio", ScoreAudioProcessor);
