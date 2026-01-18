
//------------------------------------------------------------------------------
// name: love-letter.ck
// desc: a love letter after it has happened, made with word2vec + ChucK
//
// NOTE: need a pre-trained word vector model, e.g., from
//       https://chuck.stanford.edu/chai/data/glove/
//       glove-wiki-gigaword-50-pca-3.txt (400000 words x 3 dimensions)
// author: Jillian Chang
// date: Winter 2026
//------------------------------------------------------------------------------


Word2Vec model;

me.dir() + "glove-wiki-gigaword-50-pca-3.txt" => string filepath;
//me.dir() + "glove-wiki-gigaword-50.txt" => string filepath;
// alt:          me.dir() + "glove-wiki-gigaword-50-tsne-2.txt" => string filepath;

<<< "loading model:", filepath >>>;
if( !model.load( filepath ) )
{
    <<< "cannot load model:", filepath >>>;
    me.exit();
}

// distance normalization using min/max per dimension
float mins[0], maxs[0];
model.minMax( mins, maxs );

// compute a rough upper bound for euclidean distance in this space
// (diagonal of the min-max hyper-rectangle)
0.0 => float D_MAX;
for( int i; i < model.dim(); i++ )
{
    (maxs[i] - mins[i]) => float r;
    r*r +=> D_MAX;
}
Math.sqrt(D_MAX) => D_MAX;


6 => int LINES_PER_STANZA;    
3 => int NUM_STANZAS;         
20 => int K_NEAREST;
0.30 => float P_ANALOGY;      // probability of analogy jump
0.60 => float P_ANCHOR_SHIFT; // probability to switch anchor concept

["love", "desire", "closeness", "touch", "warm", "tender", "heart"] @=> string anchors[];

// seed descriptor
"love" => string w;


// TIME
77.0 => float BPM;
(60.0 / BPM)::second => dur BEAT;

// each line has a phrase window + remaining sustain window
0.5::second => dur PHRASE_DELAY;

1.5*BEAT => dur T_LINE;
0.5*BEAT => dur T_BREATH;


// SOUND DESIGN 

// stereo keys + simple echo
Rhodey keys => Gain left => DelayL DL => left => dac.left;
keys => Gain right => DelayL DR => right => dac.right;

// overall level
0.22 => left.gain;
0.22 => right.gain;

0.35 => DL.gain; 0.25 => DR.gain;
1.2::second => DL.max => DL.delay;
1.6::second => DR.max => DR.delay;


// HEARTBEAT SYNTH 
SinOsc hbS => Gain hbG => ADSR hbEnv => dac;
Noise hbN => LPF hbF => hbG;

55 => hbS.freq;
120 => hbF.freq;

hbEnv.attackTime(0.005::second);
hbEnv.decayTime(0.05::second);
hbEnv.sustainLevel(0.0);
hbEnv.releaseTime(0.15::second);

0.6 => hbS.gain;
0.4 => hbN.gain;

// overall heartbeat level (you can tweak)
0.35 => hbG.gain;


// VECTORS + SEARCH BUFFERS
float vecLove[model.dim()];
model.getVector("love", vecLove);

float vecW[model.dim()];
float vecPrev[model.dim()];

string results[K_NEAREST];


// OPENING
chout <= IO.newline();
chout <= "Heartbeat Vows" <= IO.newline();
chout <= "----------------" <= IO.newline();
chout.flush();

model.getVector(w, vecW);
copyVec(vecPrev, vecW);


// MAIN LOOP
anchors[Math.random2(0, anchors.size()-1)] => string anchor;

for( int stanza; stanza < NUM_STANZAS; stanza++ )
{
    // determine phrase for this stanza + mode
    // 0 = like, 1 = love, 2 = hate
    string phrase;
    int mode;

    if( stanza == 0 ) { "I like you because you are " => phrase; 0 => mode; }
    else if( stanza == 1 ) { "I love you because you are " => phrase; 1 => mode; }
    else { "I hate you because you are " => phrase; 2 => mode; }

    for( int line; line < LINES_PER_STANZA; line++ )
    {
        // sometimes shift the conceptual anchor
        if( Math.random2f(0,1) < P_ANCHOR_SHIFT )
            anchors[Math.random2(0, anchors.size()-1)] => anchor;

        // decide how to pick next word
        string nextWord;

        if( Math.random2f(0,1) < P_ANALOGY )
        {
            // analogy jump: love : touch :: w : ?
            // vector = touch - love + w
            float vTouch[model.dim()];
            model.getVector("touch", vTouch);

            float vJump[model.dim()];
            for( int i; i < model.dim(); i++ )
                (vTouch[i] - vecLove[i] + vecW[i]) => vJump[i];

            model.getSimilar( vJump, K_NEAREST, results );
            results[Math.random2(0, results.size()-1)] => nextWord;
        }
        else
        {
            model.getSimilar( anchor, K_NEAREST, results );
            results[Math.random2(0, results.size()-1)] => nextWord;
        }

        // update vectors + compute distances
        nextWord => w;
        model.getVector(w, vecW);

        dist(vecPrev, vecW) => float dStep;
        dist(vecLove, vecW) => float dLove;

        // normalize 0..1 (clamp)
        clamp01(dStep / D_MAX) => float ndStep;
        clamp01(dLove / D_MAX) => float ndLove;

        // TEXT + SOUND:
        // print phrase immediately, then word after 0.5 sec, with phrase pattern + descriptor hit
        sayPhraseThenWord( phrase, w, ndStep, ndLove, anchor, mode );

        // we've already spent PHRASE_DELAY time; now sustain remainder of line window
        (T_LINE - PHRASE_DELAY) => dur remain;
        if( remain > 0::ms ) remain => now;

        // pause between lines
        T_BREATH => now;

        // advance
        copyVec(vecPrev, vecW);
    }

    // between stanzas: "then things happen."
    if( stanza < NUM_STANZAS - 1 )
    {
        chout <= IO.newline();
        chout <= "then things happen..." <= IO.newline();
        chout <= IO.newline();
        chout.flush();

        spork ~ heartbeatBeats( 2, 0.85 );

        1.5::second => now;
    }

}
chout.flush();

2::second => now;


// prints descriptor + "." and triggers stronger hit
fun void sayPhraseThenWord(
    string phrase,
    string descriptor,
    float ndStep,
    float ndLove,
    string anchor,
    int mode
)
{
    // phrase printed immediately
    chout <= phrase;
    chout.flush();

    // gentle phrase pattern during the delay window
    spork ~ phrasePatternMode( mode );

    // wait 0.5 sec
    PHRASE_DELAY => now;

    // reveal descriptor
    chout <= descriptor <= "." <= " [" <= anchor <= "]" <= IO.newline();
    chout.flush();

    // descriptor hit 
    spork ~ descriptorHitSingle( ndStep, ndLove, mode );
}


// SOUND: phrase pattern

fun void phrasePatternMode( int mode )
{
    44 => int base;
    0.125::second => dur step;

    if( mode == 0 ) // LIKE: fifths
    {
        playKeys( base, 0.22 ); step => now;
        playKeys( base+7, 0.18 ); step => now;
        playKeys( base, 0.20 ); step => now;
        playKeys( base+7, 0.16 );
    }
    else if( mode == 1 ) // LOVE: fuller and slightly brighter
    {
        playKeys( base, 0.35 ); step => now;
        playKeys( base+7, 0.28 ); step => now;
        playKeys( base, 0.24 ); step => now;  // octave touch
        playKeys( base+7, 0.25 );
    }
    else // HATE: semitone + tritone hints
    {
        playKeys( base+1, 0.20 ); step => now;   // semitone
        playKeys( base+6, 0.22 ); step => now;   // tritone
        playKeys( base,   0.18 ); step => now;
        playKeys( base+6, 0.20 );
    }
}


// SOUND: descriptor hit
// ndStep: controls velocity
// ndLove: sets main pitch register
// mode: still affects register + velocity mapping
fun void descriptorHitSingle( float ndStep, float ndLove, int mode )
{
    int base;
    int span;

    if( mode == 0 )      // LIKE: narrow, mid register
    {
        48 => base;      // C3
        24 => span;      // 2 octaves
    }
    else if( mode == 1 ) // LOVE: wide, warm
    {
        36 => base;      // C2
        72 => span;      // 6 octaves
    }
    else                 // HATE: extreme, unstable
    {
        60 => base;      // C4
        84 => span;      // 7 octaves
    }

    clampMidi(
    (base + (ndLove * span)) $ int
    ) => int midiCenter;


    // --- velocity by emotion ---
    float vel;

    if( mode == 0 )
    {
        0.30 + 0.20*ndStep => vel;   // gentle
    }
    else if( mode == 1 )
    {
        0.55 + 0.30*ndStep => vel;   // full
    }
    else
    {
        0.75 + 0.35*ndStep => vel;   // aggressive
    }

    playKeys( midiCenter, vel );
}


// play a single rhodey note
fun void playKeys( int midi, float vel )
{
    Std.mtof(midi) => keys.freq;

    // noteOn expects ~0..1
    Math.min(1.0, Math.max(0.0, vel)) => keys.noteOn;
}



// one "lub-dub" heartbeat
fun void heartbeatOnce( float intensity )
{
    // clamp
    if( intensity < 0.0 ) 0.0 => intensity;
    if( intensity > 1.0 ) 1.0 => intensity;

    (0.25 + 0.55*intensity) => hbG.gain;
    (100 + 250*intensity) => hbF.freq;

    // lub
    hbEnv.keyOn();
    0.07::second => now;
    hbEnv.keyOff();

    0.15::second => now;

    // dub (slightly stronger)
    (0.35 + 0.65*intensity) => hbG.gain;
    hbEnv.keyOn();
    0.05::second => now;
    hbEnv.keyOff();

    // rest
    0.80::second => now;
}

// do N beats
fun void heartbeatBeats( int n, float intensity )
{
    for( int i; i < n; i++ )
        heartbeatOnce( intensity );
}

// do heartbeat for a duration (non-blocking if you spork it)
fun void heartbeatFor( dur howLong, float intensity )
{
    time end;
    now + howLong => end;
    while( now < end )
        heartbeatOnce( intensity );
}



// HELPERS
fun int clampMidi( int m )
{
    if( m < 0 ) return 0;
    if( m > 127 ) return 127;
    return m;
}

fun float clamp01( float x )
{
    if( x < 0.0 ) return 0.0;
    if( x > 1.0 ) return 1.0;
    return x;
}

fun float dist( float a[], float b[] )
{
    0.0 => float s;
    (a.size() < b.size() ? a.size() : b.size()) => int n;
    for( int i; i < n; i++ )
    {
        (a[i]-b[i]) => float d;
        d*d +=> s;
    }
    return Math.sqrt(s);
}

fun void copyVec( float to[], float from[] )
{
    to.size(from.size());
    for( int i; i < from.size(); i++ ) from[i] => to[i];
}

