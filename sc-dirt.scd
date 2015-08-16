(

s.options.numBuffers = 1024 * 16;
~numChannels = 2; // adjust this to your channel setup

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



// test buffers
~buffers.keys;
~buffers['CY'][1].play

// init sc-dirt
(
var vowelFreqs, vowelAmps;
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

SynthDef(\dirt, { |out, bufnum, start=0, end=1, pan, amp = 0.1,
	speed = 1, accelerate, offset, cps, unit, doneAction=2|

	var env, sound, dur, length, rate;
	var sampleFrames, sampleDur, startFrame, sampleSampleRate;

	length = end - start;
	sampleDur = BufDur.kr(bufnum);
	sampleFrames = BufFrames.kr(bufnum);
	sampleSampleRate = BufSampleRate.kr(bufnum);

	// need to check these carefully
	// todo: account for accelerate
	// maybe implement them on the language side
	// but we need to make sure that the buffer data is there.

	rate = Select.kr(unit, [
		speed,
		cps * speed / sampleDur,
		speed / cps
	]);

	// if we accelerate, do we get shorter?
	dur = Select.kr(unit, [
		sampleDur * length,
		length / cps,
		length
	]) / rate;

	startFrame = Select.kr(unit, [
		sampleFrames * start,
		sampleSampleRate / cps * start,
		sampleSampleRate * start
	]);

	rate = rate + Sweep.kr(1, accelerate); // maybe this needs to be moved up?

	env = EnvGen.ar(Env.linen(0, dur, 0.001, amp, -4), doneAction:doneAction);
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
SynthDef(\dirt_vowel, { |out, cutoff = 440, resonance = 0.5, vowel|

	var signal = In.ar(out, ~numChannels);
	var freq = cutoff; //.linexp(0, 1, 200, 500); // adjust this and the vowel freqencies
	var vowelFreqs = \vowelFreqs.ir(1000 ! 42);
	var vowelAmps = \vowelAmps.ir(1000 ! 42);

	//resonance = resonance.linlin(0, 1, 0.0001, 0.5);
	signal = Klank.ar(`[vowelFreqs, vowelAmps, [0.1]], signal, freqscale:freq / 440, decayscale:resonance);
	// in the following we add a line to avoid hanging notes if signal is zero
	DetectSilence.ar(LeakDC.ar(signal) + Line.ar(1, 0, 0.0001), doneAction:2);
	ReplaceOut.ar(out, signal);

}).add;

// would be nice to have some more parameters in some cases

SynthDef(\dirt_crush, { |out, crush = 4|
	var signal = In.ar(out, ~numChannels);
	signal = signal.round(0.5 ** crush);
	DetectSilence.ar(LeakDC.ar(signal), doneAction:2);
	ReplaceOut.ar(out, signal)
}).add;

SynthDef(\dirt_hpf, { |out, hcutoff = 440, hresonance = 0|
	var signal = In.ar(out, ~numChannels);
	signal = RHPF.ar(signal, hcutoff, hresonance.linexp(0, 1, 1, 0.001));
	DetectSilence.ar(LeakDC.ar(signal), doneAction:2);
	ReplaceOut.ar(out, signal)
}).add;

SynthDef(\dirt_bpf, { |out, bandqf = 440, bandq = 10|
	var signal = In.ar(out, ~numChannels);
	signal = BPF.ar(signal, bandqf, 1/bandq) * max(bandq, 1.0);
	DetectSilence.ar(LeakDC.ar(signal), doneAction:2);
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



// data derived from the Vowel Quark, Bovermann et. al.
// using the tenor register. In the future, we could inculde the quark and allow for more variation

vowelFreqs = [
		[ 649.59561860561, 650.90403735638, 648.99622011185, 648.366091609, 652.09045100212, 653.35997462273, 646.56425261497, 653.64248585701, 646.00126409531, 645.02200603485, 655.36039423943, 643.85358524323, 656.15535140038, 643.27883720398, 656.73678278923, 657.60062921047, 642.36428868771, 641.22396802902, 658.8004720211, 659.5901376009, 640.393902421, 660.54089546204, 639.18885338306, 638.39233958721, 661.89248669147, 663.06574034691, 636.77858877182, 636.01250135899, 664.35531592369, 665.10470879078, 634.52188813686, 634.10799562931, 666.3013343811, 667.1966445446, 632.67150199413, 631.90361535549, 668.23925065994, 631.11126148701, 669.16529798508, 669.52723038197, 629.63742339611, 629.30747449398 ],
		[ 399.9916986227, 400.93791294098, 398.89936923981, 401.55283129215, 397.72210657597, 397.03377437592, 403.45854604244, 396.25659453869, 404.18037235737, 394.83242475986, 405.33533024788, 405.64196121693, 394.10735535622, 406.574893713, 392.65933072567, 407.6961145401, 391.89510679245, 391.46057629585, 408.70386898518, 390.2575032711, 409.94320738316, 389.49363875389, 411.20810031891, 411.9741011858, 387.54281413555, 413.0281816721, 386.90048503876, 413.77433586121, 385.62578701973, 414.56579315662, 385.343547225, 384.25853312016, 415.76992511749, 416.65739226341, 382.64730131626, 382.41220319271, 418.36822926998, 419.04109358788, 380.53100395203, 379.96380650997, 420.29295301437, 379.16601407528 ],
		[ 290.47805118561, 290.91723334789, 288.89343726635, 292.13493859768, 287.77924191952, 293.18628907204, 286.54065823555, 293.58844542503, 286.06088256836, 284.84309208393, 295.33133304119, 295.8685990572, 284.10716497898, 283.33681631088, 297.12341940403, 297.91807329655, 282.05331778526, 298.53071928024, 280.57154381275, 299.68851280212, 280.04445576668, 300.70206940174, 279.26188695431, 301.76263976097, 277.67277252674, 276.88533163071, 303.42577624321, 303.82426309586, 275.84050679207, 304.5556306839, 274.59082627296, 274.1650686264, 306.0103610754, 273.20024454594, 307.3653845787, 307.71148371696, 271.71732592583, 309.40105068684, 270.59525632858, 309.55144965649, 269.82971322536, 310.71728754044 ],
		[ 400.22690391541, 399.11511611938, 401.26759135723, 401.57939493656, 397.51238656044, 402.94317114353, 396.92631459236, 396.48486375809, 403.66048121452, 405.07825791836, 394.62416636944, 394.30108559132, 406.07801806927, 406.51278936863, 393.2609937191, 407.9802492857, 391.93112778664, 408.67394292355, 390.68890500069, 409.98697245121, 389.99255907536, 389.42846775055, 410.64605796337, 411.56585335732, 388.23697447777, 413.0941426754, 386.90151870251, 413.67589509487, 385.77261149883, 384.77992236614, 415.41368174553, 384.059071064, 416.39875328541, 383.26967275143, 416.92220556736, 381.79082965851, 418.44259381294, 381.20094645023, 418.84105575085, 419.56455540657, 380.19686257839, 379.1351338625 ],
		[ 350.18106436729, 349.27576863766, 351.46224999428, 351.85456526279, 347.73545324802, 352.95194458961, 346.78272259235, 353.77715289593, 345.81103622913, 345.45479154587, 355.47054517269, 355.59611809254, 344.3683744669, 356.85094428062, 343.09823536873, 342.41967952251, 358.03570568562, 358.68489480019, 341.25241720676, 359.90372526646, 340.01676857471, 338.77504253387, 361.41577732563, 338.06614232063, 362.45562195778, 362.70864248276, 337.26509654522, 336.26165401936, 364.12331187725, 364.56136250496, 334.79247426987, 334.32478559017, 365.92240977287, 333.39136135578, 366.70006263256, 332.49189662933, 368.05081021786, 368.50375342369, 331.13607430458, 370.0052959919, 329.63990962505, 370.5103096962 ]
	];

	vowelAmps =  [
		[ 0.99367898932708, 0.98513166172761, 0.98341203289594, 0.97273306821491, 0.96511133059172, 0.94414006927205, 0.94283239937754, 0.93953576713676, 0.93367967083895, 0.91797066180723, 0.91201840722943, 0.89957259431803, 0.89955979204872, 0.89065832159303, 0.89055576757132, 0.87734491198979, 0.87665554196461, 0.85950391519289, 0.85932112908559, 0.84766208463905, 0.84723026892181, 0.83383495111267, 0.82972323069582, 0.8183504754143, 0.81456700497731, 0.79820399558304, 0.79578467960765, 0.78529101653569, 0.78059898148717, 0.77054803213388, 0.76526790654544, 0.75979929524514, 0.75476739864365, 0.74317296456071, 0.74112083046044, 0.73132520138887, 0.7298962268969, 0.72135316119456, 0.7183036444742, 0.71382327426628, 0.7031646902951, 0.6991560699224 ],

		[ 0.99983561136708, 0.98159682483851, 0.97843872316051, 0.96971546123298, 0.95589054165134, 0.94294837742023, 0.93379929134579, 0.92854617403614, 0.92054540620145, 0.90272282639577, 0.8997287276816, 0.89428160643442, 0.88985287098621, 0.87791057270296, 0.86469700186295, 0.85863150429244, 0.85170848211887, 0.8444105247231, 0.84166499926602, 0.82452946241588, 0.82125853305997, 0.81215007574068, 0.80094138000444, 0.78888276466074, 0.78137142615717, 0.77258535637281, 0.77149469629436, 0.76125280649834, 0.75226256316712, 0.74941381659317, 0.74806949495974, 0.73216656758901, 0.73175404007795, 0.71900539793141, 0.70917255450797, 0.70587837039151, 0.69505230253517, 0.68585179024992, 0.68006425547098, 0.67246790977961, 0.66905714450549, 0.66192664887004 ],

		[ 0.98356850275198, 0.96871106949932, 0.9623755287691, 0.92867974223061, 0.92592169540922, 0.89545047408578, 0.88701654017324, 0.88305654642513, 0.87238938956759, 0.83633601978048, 0.83129552358206, 0.81595983706679, 0.8152747556882, 0.79379633999936, 0.78123529243993, 0.76001317597616, 0.75925998911125, 0.7440461616427, 0.72125293549663, 0.71478157917952, 0.70819707407547, 0.69010918029925, 0.6892476496452, 0.6652036601793, 0.65231405840735, 0.63475272193812, 0.62794547000822, 0.61933283717041, 0.61217894846629, 0.60383172643487, 0.58623106035383, 0.57764435538266, 0.57414297291354, 0.55864830374083, 0.54780364516162, 0.5412720561594, 0.53066242234386, 0.51048747361496, 0.51042214096459, 0.50783351563262, 0.49705784544188, 0.48772357789215 ],

		[ 0.99247698184972, 0.97010186310274, 0.95733531124133, 0.94705086877311, 0.91769357109293, 0.90335223362422, 0.89924463618458, 0.88559354992046, 0.88118372284479, 0.83895603875022, 0.83029577454369, 0.8210522653834, 0.81040223002099, 0.79829033377888, 0.79198791101998, 0.75873183584173, 0.75632000596522, 0.74072095490052, 0.72445535580179, 0.70779327578945, 0.70718410295804, 0.69349548078944, 0.69182150817004, 0.67013326721815, 0.66544663566287, 0.63559189894306, 0.63535502595472, 0.6229170756434, 0.61098148049157, 0.59032280740178, 0.58654284334936, 0.57576049519379, 0.5668767287172, 0.56022523648864, 0.55669658647137, 0.53224122787921, 0.52815451982317, 0.52147293590773, 0.52091980257726, 0.50803635358269, 0.50364214468872, 0.48545051202634 ],

		[ 0.99405577426969, 0.97551733269303, 0.95090566575304, 0.9380713210682, 0.92481181704592, 0.90308464522835, 0.89477712818208, 0.87763842278868, 0.86514940675241, 0.85453465554443, 0.8276462227786, 0.82405466157205, 0.82296102061265, 0.78901086314904, 0.78752416780576, 0.7692221023337, 0.75729433318679, 0.74046002459105, 0.73872823850166, 0.70985983104982, 0.70776401260521, 0.67795492456785, 0.67365216934193, 0.66150338127175, 0.64983125959874, 0.64416381949426, 0.64339334506361, 0.62140546393667, 0.61337674105204, 0.60414582781317, 0.59056051860794, 0.58106653273873, 0.57634362905556, 0.56257208264789, 0.56103784931547, 0.54530764560652, 0.53541437667092, 0.52708744308184, 0.52027987656073, 0.50040045276119, 0.49399257833419, 0.49173274023054 ]
	];


/*
Functions for sending synths to the server.
*/

~sendSynth = { |instrument, args|
	s.sendMsg(\s_new, instrument,
		-1, // no id
		1, // add action: addToTail
		1, // send to group 1
		*args.asOSCArgArray // append all other args
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

	var amp, allbufs, buffer, group, latency;
	var instrument, key, index, sample;
	var temp;

	#key, index = name.asString.split($:);
	key = key.asSymbol;
	allbufs = ~buffers[key];
	index = (index ? 0).asInteger;

	if(allbufs.notNil) {
		instrument = \dirt;
		buffer = allbufs.wrapAt(index).bufnum;
		sample = name.identityHash;
	} {
		instrument = key;
	};

	if(speed < 0) { temp = end; end = start; start = temp;  };


	if(allbufs.notNil or: { SynthDescLib.at(key).notNil }) {

		unit = #[\r, \c, \s].indexOf(unit) ? 0;
		amp = pow(gain, 4);

		if(scheduleTime.notNil) {
			latency = scheduleTime - Main.elapsedTime;
			if(latency > 2) {
				"too long delay. Networks clocks may not be in sync".warn;
				latency = 0.2;
			}
		};

		s.makeBundle(latency, { // use this to build a bundle

			if(cutgroup != 0) {
				// set group 1, in which all synths are living
				s.sendMsg(\n_set, 1, \gateCutGroup, cutgroup, \gateSample, sample);
			};

			// set global delay synth parameters
			if(delaytime != 0 or: { delayfeedback != 0 }) {
				s.sendMsg(\n_set, ~delaySynthID, \delaytime, delaytime, \delayfeedback, delayfeedback);
			};

			~sendSynth.(instrument, [
				unit:unit,
				speed: speed,
				bufnum: buffer,
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
							vowelFreqs: vowelFreqs.clipAt(vowel),
							vowelAmps: vowelAmps.clipAt(vowel),
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
						out: ~bus.index
					]
				);
			};
			if(hcutoff != 0) {
				~sendSynth.(\dirt_hpf,
					[
						hcutoff: hcutoff,
						hresonance: hresonance,
						out: ~bus.index
					]
				);
			};
			if(bandqf != 0) {
				~sendSynth.(\dirt_bpf,
					[
						bandqf: bandqf,
						bandq: bandq,
						out: ~bus.index
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

	} {
		"no sample or instrument found for this name: %\n".postf(name);
	}
};


OSCdef(\dirt, { |msg, time|
	~dirt.(time, *msg[1..]);
}, '/play');
)


~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \i, resonance: 1);
~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \a, resonance: 0.6);
~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \o, resonance: 0.6);

// some tests


~dirt.(nil, 1, 'CY:10', speed: 1);
~dirt.(nil, 1, 'CY:10', speed: 3);
~dirt.(nil, 1, 'CY:10', speed: -1); // backwards
~dirt.(nil, 1, 'CY:10', speed: -3); // backwards
~dirt.(nil, 1, 'CY:10', speed: -1, accelerate:-0.9); // backwards accellerate


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

(
Tdef(\x, {
	loop {
		~dirt.(nil, 1, 'CY:10', 0, 0.1.rand, 1.0.rand, 1 + 1.3.rand2, 2.rand2, accelerate:0, vowel: "aeiou".choose.asSymbol, cutoff: 1000);
		(0.2 * [1, 2, 1/3]).choose.wait;
	}
}).play;
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


// test vowels
~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \a);


~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \i, resonance: 1);
~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \a, resonance: 0.6);
~dirt.(nil, 1, 'CY:10', speed: 1, vowel: \o, resonance: 0.6);

(
Tdef(\x, {
	loop {
		~dirt.(nil, 1, 'CY:1', speed: 0.5, vowel: "aeiou".choose.asSymbol, resonance: 0.3);
		(1 * [1, 2, 1/3]).choose.wait;
	}
}).play;
)
s.reboot



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

