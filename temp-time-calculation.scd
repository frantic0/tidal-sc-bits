
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