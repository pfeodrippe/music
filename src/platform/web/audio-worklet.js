class ScoreAudioProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const wasmModule = options.processorOptions.wasmModule;
    this.instance = new WebAssembly.Instance(wasmModule, {});
    this.exports = this.instance.exports;
    this.memory = this.exports.memory;
    this.exports.score_audio_reset();
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
    const mono = new Float32Array(this.memory.buffer, pointer, frames);
    for (const channel of output) channel.set(mono);
    this.analyzeInput(inputs[0]?.[0]);
    return true;
  }
}

registerProcessor("score-audio", ScoreAudioProcessor);
