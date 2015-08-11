

/* ------------------------------------------

First Part: Initialise the Server

*/


(

s.options.numBuffers = 1024 * 16;
~numChannels = 2; // adjust this to your channel setup
~timingOffset = 0; // adjust an offset for the OSC timestamps here

// we need this here, because it is a global effect (repeated below under effects)
SynthDef(\dirt_delay, { |out, delayBus, delaytime, delayfeedback|
	var signal = In.ar(delayBus, ~numChannels);
	signal = SwitchDelay.ar(signal, 1, 1, delaytime, delayfeedback); // try this from sc3-plugins
	Out.ar(out, signal);
}).add;

SynthDef(\dirt_limiter, { |out|
	var signal = In.ar(out, ~numChannels);
	ReplaceOut.ar(signal, Limiter.ar(signal))
}).add;


s.tree = {
	/*
	we use one private bus, so we can use the public one for mixing everything together (see the "dirt_monitor" synth def)
	*/
	~bus = Bus.audio(s, ~numChannels);
	~delayBus =  Bus.audio(s, ~numChannels);
	~delaySynthID = s.nextNodeID;
	s.sendBundle(nil, // add delay and limiter after group 1
		[\s_new, \dirt_limiter, -1, 3, 1, \out, 0],
		[\s_new, \dirt_delay, ~delaySynthID, 3, 1, \delayBus, ~delayBus.index, \out, 0]
	);
};
s.reboot;
)


/* ------------------------------------------

Second Part: Load whatever samples you want to use

*/

(
var path = "samples".resolveRelative; // put your sample path here
var folderPaths = pathMatch(path +/+ "**");
~buffers = ();

folderPaths.do { |folderPath|
	PathName(folderPath).filesDo { |filepath|
		var buf, name;
		if(filepath.extension == "wav" or: { filepath.extension == "WAV" }) {
			buf = Buffer.read(s, filepath.fullPath);
			name = filepath.folderName;
			~buffers[name.asSymbol] = ~buffers[name.asSymbol].add(buf)
		}
	};
};

)




/* -----------------------------------------


Third Part: init scdirt

*/


(
/*
in order to avoid bookkeeping on the language side, we implement cutgroups as follows:
The language initialises the synth with its sample id (some number that correlates with the sample name) and the cutgroup. Before we start the new synth, we send a /set message to all synths, and those that match the specifics will be released.
*/

~gateCutGroup = {
	// this is necessary because the message "==" tests for objects, not for signals
	var same = { |a, b| BinaryOpUGen('==', a, b) };
	var sameCutGroup = same.(\cutGroup.kr(0), abs(\gateCutGroup.kr(0)));
	var sameSample = same.(\sample.kr(0), \gateSample.kr(0));
	var which = \gateCutGroup.kr(0).sign; // -1, 0, 1
	var free = Select.kr(which + 1, // 0, 1, 2
		[
			sameSample,
			0.0, // default cut group 0 doesn't ever cut
			1.0
		]
	) * sameCutGroup; // same cut group is mandatory

	EnvGen.kr(Env.asr(0, 1, 0.01), 1 - free, doneAction:2);
};

/*
note: "sustain" is the convention in sclang for the total duration of a sound (not the release part)
*/
SynthDef(\dirt, { |out, bufnum, start=0, end=1, startFrame, sustain, pan, amp = 0.1,
	speed = 1, accelerate, offset, cps, unit, doneAction=2|

	var env, sound, rate;

	rate = speed + Sweep.kr(1, accelerate); // maybe this needs to be moved up?
	env = EnvGen.ar(Env.linen(0, sustain, 0.001, amp, -4), doneAction:doneAction);

	sound = PlayBuf.ar(1,
		bufnum,
		// bufratescale adjusts the rate if sample doesn't have the same rate as soundcard
		rate * BufRateScale.kr(bufnum),
		0,
		startFrame
	);
	env = env * ~gateCutGroup.value; // this synth can be freed by cutgroup mechanism
	OffsetOut.ar(out,
		if(~numChannels == 2) {
			Pan2.ar(sound, (pan * 2) - 1, env)
		} {
			PanAz.ar(~numChannels, sound, pan, env)
		}
	);
}).add;


/*
The following effect synths are freed when input is silent for longer than 0.1 sec. This makes it unnecessary to keep track of any synths. But this may cause problems with samples that contain silence. One way to solve this involves bookkeeping of synths on the language side (haskell or sclang). For now, we use the simplest possible way.
*/

// these are just placeholders, not sure how they are best translated

// we need to select formant bands for the vowels in sclang (at least this would be the most efficient)
SynthDef(\dirt_vowel, { |out, cutoff = 440, resonance = 0.5, vowel, sustain = 1|
	var signal = In.ar(out, ~numChannels);
	var freq = cutoff.linexp(0, 1, 200, 500); // adjust this and the vowel freqencies
	var vowelFreqs = Select.kr(vowel, [
		[800, 1150, 2800, 3500, 4950],
		[400, 1600, 2700, 3300, 4950],
		[350, 1700, 2700, 3700, 4950],
		[450, 800, 2830, 3500, 4950],
		[325, 700, 2530, 3500, 4950]
	]);
	signal = signal * EnvGen.kr(Env.linen(0, sustain, 0.02));
	signal = Formlet.ar(signal, (cutoff / 440) * vowelFreqs, resonance * 0.1, resonance * 0.2); // not sure how to use this here.
	signal = signal.sum; // sum all filters
	DetectSilence.ar(LeakDC.ar(signal), doneAction:2);
	ReplaceOut.ar(out, signal)
}).add;

// would be nice to have some more parameters in some cases

SynthDef(\dirt_crush, { |out, crush = 4, sustain = 1|
	var signal = In.ar(out, ~numChannels);
	signal = signal * EnvGen.kr(Env.linen(0, sustain, 0.02), doneAction:2);
	signal = signal.round(0.5 ** crush);
	ReplaceOut.ar(out, signal)
}).add;

SynthDef(\dirt_hpf, { |out, hcutoff = 440, hresonance = 0, sustain = 1|
	var signal = In.ar(out, ~numChannels);
	var env = EnvGen.kr(Env.linen(0, sustain, 0.02));
	signal = signal * env;
	signal = RHPF.ar(signal, hcutoff, hresonance.linexp(0, 1, 1, 0.001));
	DetectSilence.ar(LeakDC.ar(signal) + (100 * env), doneAction:2);
	ReplaceOut.ar(out, signal)
}).add;

SynthDef(\dirt_bpf, { |out, bandqf = 440, bandq = 10, sustain = 1|
	var signal = In.ar(out, ~numChannels);
	var env = EnvGen.kr(Env.linen(0, sustain, 0.02));
	signal = signal * env;
	signal = BPF.ar(signal, bandqf, 1/bandq) * max(bandq, 1.0);
	DetectSilence.ar(LeakDC.ar(signal) + (100 * env), doneAction:2);
	ReplaceOut.ar(out, signal)
}).add;

// the monitor does the mixing and zeroing of the busses

SynthDef(\dirt_monitor, { |out, in, delayBus, delay = 0|
	var signal = In.ar(in, ~numChannels);
	DetectSilence.ar(signal, doneAction:2);
	Out.ar(out, signal);
	Out.ar(delayBus, signal * delay);
	ReplaceOut.ar(in, Silent.ar(~numChannels)) // clears bus signal for subsequent synths
}).add;


SynthDef(\dirt_delay, { |out, delayBus, delaytime, delayfeedback|
	var signal = In.ar(delayBus, ~numChannels);
	signal = SwitchDelay.ar(signal, 1, 1, delaytime, delayfeedback); // try this from sc3-plugins
	Out.ar(out, signal);
}).add;

/*
Functions for sending synths to the server.
*/

~sendSynth = { |instrument, args, group = 1|
	s.sendMsg(\s_new, instrument,
		-1, // no id
		1, // add action: addToTail
		group,
		*args // append all other args
	)
};


~dirt = {
	|scheduleTime, cps = 1, name, offset = 0, start = 0, end = 1, speed = 1, pan = 0, velocity,
	vowel, cutoff = 300, resonance = 0.5,
	accelerate = 0, shape, krio, gain = 1, cutgroup = 0,
	delay = 0, delaytime = 0, delayfeedback = 0,
	crush = 0,
	coarse = 0,
	hcutoff = 0, hresonance = 0,
	bandqf = 0, bandq = 0,
	unit = \r|

	var amp, allbufs, buffer, bufnum, group, latency;
	var instrument, key, index, sample;
	var startFrame, numFrames, sustain, bufferDuration, length, sampleRate;

	#key, index = name.asString.split($:);
	key = key.asSymbol;
	allbufs = ~buffers[key];
	index = (index ? 0).asInteger;

	if(allbufs.isNil and: { SynthDescLib.at(key).isNil }) {
		"Dirt: no sample or synth definition found: %".format(key).postln;
	} {

		if(allbufs.notNil) {
			instrument = \dirt;
			buffer = allbufs.wrapAt(index);
			bufnum = buffer.bufnum;
			numFrames = buffer.numFrames;
			bufferDuration = buffer.duration;
			sampleRate = buffer.sampleRate;
			sample = name.identityHash;
		} {
			instrument = key;
			sampleRate = s.sampleRate;
			numFrames = sampleRate; // assume one second
			bufferDuration = 1.0;
		};

		if(end >= start) {
			length = end - start;
		} {
			// backwards
			length = start - end;
			speed = speed.neg;
		};

		switch(unit,
			\r, {
				startFrame = numFrames * start;
				sustain = bufferDuration * length;
			},
			\c, {
				sustain = length / cps;
				speed = speed * cps;
				startFrame = start * numFrames;
			},
			\s, {
				startFrame = start * sampleRate;
				sustain = length * sampleRate;
			}
		);

		amp = pow(gain, 4);

		if(scheduleTime.notNil) {
			latency = scheduleTime - Main.elapsedTime + ~timingOffset;
			if(latency > 2) {
				"too long delay. Networks clocks may not be in sync".warn;
				latency = 0.2;
			}
		};

		s.makeBundle(latency, { // use this to build a bundle
			var group;

			if(cutgroup != 0) {
				// set group 1, in which all synths are living
				s.sendMsg(\n_set, 1, \gateCutGroup, cutgroup, \gateSample, sample);
			};

			// set global delay synth parameters
			if(delaytime != 0 or: { delayfeedback != 0 }) {
				s.sendMsg(\n_set, ~delaySynthID, \delaytime, delaytime, \delayfeedback, delayfeedback);
			};

			group = s.nextNodeID;
			~sendSynth.(instrument, [
				speed: speed,
				bufnum: bufnum,
				sustain: sustain,
				startFrame: startFrame,
				start: start,
				end: end,
				pan: pan,
				accelerate: accelerate,
				amp: amp,
				offset: offset,
				cutGroup: cutgroup.abs, // ignore negatives here!
				sample: sample,
				cps: cps,
				out: ~bus.index]
			);

			if(vowel.notNil) {
				vowel = [\a, \e, \i, \o, \u].indexOf(vowel); // convert to number
				if(vowel.notNil) {
					~sendSynth.(\dirt_vowel,
						[
							out: ~bus.index,
							vowel: vowel,
							cutoff: cutoff,
							resonance: resonance
						]
					);
				};
			};

			if(crush != 0) {
				~sendSynth.(\dirt_crush,
					[
						crush: crush,
						out: ~bus.index,
						sustain: sustain
					]
				);
			};
			if(hcutoff != 0) {
				~sendSynth.(\dirt_hpf,
					[
						hcutoff: hcutoff,
						hresonance: hresonance,
						out: ~bus.index,
						sustain: sustain
					]
				);
			};
			if(bandqf != 0) {
				~sendSynth.(\dirt_bpf,
					[
						bandqf: bandqf,
						bandq: bandq,
						out: ~bus.index,
						sustain: sustain
					]
				);
			};

			~sendSynth.(\dirt_monitor,
				[
					in: ~bus.index,  // read from private
					out: 0,     // write to public,
					delayBus: ~delayBus.index,
					delay: delay
				]
			);


		});

	}
};


OSCdef(\dirt, { |msg, time|
	msg.postcs;
	~dirt.(time, *msg[1..]);
}, '/play');
)




// -----------------------------------------------------------------------------------------


// some tests

(
Tdef(\x, {
	loop {
		~dirt.(nil, 1, 'CY:10', 0, 0.1.rand, 1.0.rand, 1 + 1.3.rand2, 2.rand2, accelerate:0);
		(0.2 * [1, 2, 1/3]).choose.wait;
	}
}).play;
)

(
Tdef(\x, {
	loop {
		~dirt.(nil, 1, 'CY:10', 0, 0.1.rand, 1.0.rand, 1 + 1.3.rand2, 2.rand2, accelerate:0.2.rand2, crush:8);
		(0.2 * [1, 2, 1/3]).choose.wait;
	}
}).play;
)

// test unit
// \r
(
Tdef(\x, {
	var name = 'CY';
	var buffer = ~buffers[name][0];
	var cps = 1;
	loop {
		~dirt.(nil, cps:cps, name:name, unit: \r, start: 0, end: 0.5);
		(1/cps).wait;
	}
}).play
)

// no?
// \c
(
Tdef(\x, {
	var name = 'CY';
	var buffer = ~buffers[name][0];
	var cps = 1.0.rand + 0.5;
	loop {
		~dirt.(nil, cps:cps, name:name, unit: \c);
		(1/cps).wait;
	}
}).play
)

// \s
(
Tdef(\x, {
	var name = 'CY';
	var buffer = ~buffers[name][0];
	var cps = 0.5;
	loop {
		~dirt.(nil, cps:cps, name:name, unit: \c, start: 0, end: 0.5);
		0.5.wait;
	}
}).play
)












// cutgroup tests
~dirt.(nil, 1, 'CY:10', speed: 0.02, cutgroup: -8); // really slow, to keep it on
~dirt.(nil, 1, 'CY:10', speed: 0.02, cutgroup: -8); // cut the old one
~dirt.(nil, 1, 'CY:10', speed: 0.02, cutgroup: -8); // ... again


//  With negative, only stop the same sample from playing in the same cutgroup
~dirt.(nil, 1, 'CY:9', speed: 0.02, cutgroup: -8); // a different sample, is added
~dirt.(nil, 1, 'CY:9', speed: 0.02, cutgroup: -8); // the same sample, frees

//  with positive integers, stop samples playing that are in the same cutgroup.
~dirt.(nil, 1, 'CY:10', speed: 0.02, cutgroup: 8); // should free all others


// test effects:
~dirt.(nil, 1, 'CY:10', speed: 0.1, crush: 4);
~dirt.(nil, 1, 'CY:10', speed: 1, hcutoff: 1000, hresonance: 20);
~dirt.(nil, 1, 'CY:10', speed: 1, hcutoff: 3000, hresonance: 10);
~dirt.(nil, 1, 'CY:10', speed: 1, bandqf: 3000, bandq: 100);
~dirt.(nil, 1, 'CY:10', speed: 1, bandqf: 3000, bandq: 100, crush: 4);
~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \a);

~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \i, resonance: 1.5);
~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \a, resonance: 1.5);
~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \o, resonance: 1.5);


// test delay:

~dirt.(nil, 1, 'CY:10', speed: 1, delaytime: 0.8, delay: 1);
~dirt.(nil, 1, 'CY:10', speed: 1, delaytime: 0.8, delay: 0);
~dirt.(nil, 1, 'CY:10', speed: 1, delaytime: 0.2, delay: 1);


// test replacement:

// todo: need to factor out unit calculations to be able to add them here.
// alternatively, we do the calculations on the language side, but this will make it necessary that we know all teh buffer data (this wasn't working when testing, so this is on the safe side)

// you can livecode this while running tidal.
(
SynthDef(\imp, { |out, speed = 1, start=0, end=1, pan, accelerate, amp = 0.1, offset|
	var env, sound, dur, rate, phase;
	dur = (end - start) / speed;
	env = EnvGen.ar(Env.linen(0, 0.2, 0.8, amp, -4), timeScale:dur, doneAction:2);
	phase = Line.ar(start, end, dur);
	rate = (start + 1) * (speed + Sweep.kr(1, accelerate));
	sound = Blip.ar(rate.linexp(0, 1, 15 * [1, 2, 5], 200), 200 * phase).sum;
	env = env * ~gateCutGroup.value; // this synth can be freed by cutgroup mechanism
	OffsetOut.ar(out,
		if(~numChannels==2,Pan2.ar(sound, (pan*2)-1, env),
			PanAz.ar(~numChannels, sound, pan, env)
		)
	);
}).add;
)


~dirt.(nil, 1, 'imp', speed: 1, start: 0, end: 1);
~dirt.(nil, 1, 'imp', speed: 1, start: 0.5, end: 1);
~dirt.(nil, 1, 'imp', speed: 0.1, start: 0, end: 1, accelerate: 3);

(
Tdef(\x, {
	loop {
		~dirt.(nil, 1, 'imp', 0, speed:rrand(1.0, 2.0), start:0, end: 2.0.rand, accelerate:1, hcutoff: 4000.0.rand, hresonance: 0.5.rand);
		0.5.wait;
	}
}).play;
)

~buffers[\CY][0].duration;
~buffers[\CY][0].samplerate;


// network test
n = NetAddr("127.0.0.1", 57120);
// Should pan left and right?
n.sendMsg(\play, 1, 'CY:10',0,0,1,1,0);
n.sendMsg(\play, 1, 'CY:10',0,0,1,1,1);

// feeding back
n.sendMsg(\play, 1, 'CY:10',0,0,1,1,0.5,0,"o");

n.sendMsg(\play, 1, 'CY:10',0,0,1,1,0.5,0);


n.sendMsg(\play, 1, 'breaks125');

n.sendMsg(\play, 1, \imp);

(
n.sendBundle(1.2, [\play, 1, 'CY']);
n.sendBundle(1.2, [\play, 1, 'CY']);
)

OSCFunc.trace(true, true);
OSCFunc.trace(false, false);
