//------------------------------------------------------------------------------
// name: semantic-crossfade-input.ck
// desc: poem that morphs from WORD_A -> WORD_B using Word2Vec + 50D GloVe model
//
// NOTE: need a pre-trained word vector model, e.g., from
//       https://chuck.stanford.edu/chai/data/glove/
//       glove-wiki-gigaword-50-pca-3.txt (400000 words x 3 dimensions)
// author: Jillian Chang
// date: Winter 2026
//------------------------------------------------------------------------------

ConsoleInput in;
StringTokenizer tok;
string line[0];

Word2Vec model;
me.dir() + "glove-wiki-gigaword-50.txt" => string filepath;

if( !model.load(filepath) )
{
    <<< "cannot load model:", filepath >>>;
    me.exit();
}

250::ms => dur T_WORD;
25::second => dur TOTAL_TIME;

(TOTAL_TIME / T_WORD) $ int => int TOTAL_WORDS;

8 => int WORDS_PER_LINE;
0.5::second => dur T_LINE_PAUSE;

40 => int K_NEAREST; 
string cand[K_NEAREST];

// no repeat
60 => int RECENT_N;
string recent[RECENT_N];
0 => int recentIdx;

//get word from user input
fun string getWord( string prompt )
{
    string word;
    while( true )
    {
        in.prompt( prompt ) => now;
        
        while( in.more() )
        {
            line.clear();
            tok.set( in.getLine() );
            while( tok.more() )
            {
                line << tok.next().lower();
            }
            // if non-empty, take first word
            if( line.size() > 0 )
            {
                line[0] => word;
                float testVec[model.dim()];
                if( model.getVector( word, testVec ) )
                {
                    return word;
                }
                else
                {
                    chout <= "Word not in vocabulary: " <= word <= IO.newline();
                    chout <= "Please try another word." <= IO.newline();
                    chout.flush();
                }
            }
        }
    }
    return "";
}

ModalBar bar => NRev rev => dac;
0.12 => rev.mix;
0 => bar.preset;

// morphing sound chain
TriOsc morph => LPF morphLPF => NRev morphRev => dac;
.15 => morphRev.mix;
0.0 => morph.gain; 

// helpers

fun int isRecent( string w )
{
    for( int i; i < recent.size(); i++ )
        if( recent[i] == w ) return true;
    return false;
}

fun void pushRecent( string w )
{
    w => recent[recentIdx];
    (recentIdx + 1) % RECENT_N => recentIdx;
}

fun void blend( float a[], float b[], float t, float out[] )
{
    for( int i; i < out.size(); i++ )
        (1.0 - t) * a[i] + t * b[i] => out[i];
}

fun float magnitude( float x[] )
{
    0.0 => float sum;
    for( int i; i < x.size(); i++ )
        x[i]*x[i] +=> sum;
    return Math.sqrt(sum);
}

// play morphing sound
fun void playMorphing()
{
    // sweeping filter effect
    0.05 => morph.gain;
    220.0 => morph.freq;
    200.0 => morphLPF.freq;
    2.0 => morphLPF.Q;
    
    // sweep filter up and down (0.5 second total)
    for( 0 => int i; i < 25; i++ )
    {
        Math.remap( i, 0, 24, 200.0, 4000.0 ) => morphLPF.freq;
        10::ms => now;
    }
    for( 0 => int i; i < 25; i++ )
    {
        Math.remap( i, 0, 24, 4000.0, 200.0 ) => morphLPF.freq;
        10::ms => now;
    }
    
    // ensure it stops
    0.0 => morph.gain;
}


// print + play one word
fun void emitWord( string w, float t )
{
    // ensure morphing sound is off
    0.0 => morph.gain;
    
    chout <= w <= " "; chout.flush();

    float tmp[model.dim()];
    model.getVector( w, tmp );
    magnitude(tmp) => float mag;

    // pitch follows the crossfade 
    Math.remap( t, 0, 1, 38, 82 ) => float midi;

    // brightness from magnitude (clamped)
    Math.remap( mag, 2.0, 8.0, 0.2, 1.0 ) => float hard;
    Math.clampf( hard, 0.1, 1.0 ) => bar.stickHardness;

    // set pitch
    midi $ int => Std.mtof => bar.freq;

    // dynamics gently increase toward end
    Math.remap( t, 0, 1, 0.45, 1.0 ) * Math.random2f(0.6, 1.0) => bar.noteOn;
}


// choose a next word from cand[] with structure + anti-repeat
fun string chooseNextWord( float t )
{
    int idx;

    // end: tighten to arrive
    if( t > 0.85 )
        Math.random2(0, 3) => idx;
    // turbulence window
    else if( t > 0.4 && t < 0.6 )
        Math.random2(8, cand.size()-1) => idx;
    // otherwise stable
    else
        Math.random2(0, 10) => idx;

    // avoid recent repeats
    0 => int tries;
    while( isRecent(cand[idx]) && tries < 25 )
    {
        Math.random2(0, cand.size()-1) => idx;
        tries++;
    }

    return cand[idx];
}


fun void generatePoem( string WORD_A, string WORD_B )
{
    // reset recent words for new poem
    0 => recentIdx;
    for( 0 => int i; i < recent.size(); i++ )
    {
        "" => recent[i];
    }
    
    // vectors for endpoints + working buffers
    float vecA[model.dim()];
    float vecB[model.dim()];
    float v[model.dim()];
    float tmp[model.dim()];
    
    // fetch endpoint vectors
    if( !model.getVector( WORD_A, vecA ) )
    {
        <<< "Word not in vocabulary:", WORD_A >>>;
        return;
    }
    if( !model.getVector( WORD_B, vecB ) )
    {
        <<< "Word not in vocabulary:", WORD_B >>>;
        return;
    }
    
    chout <= IO.newline()
          <= "\"Semantic Crossfade\"" <= IO.newline()
          <= "[" <= WORD_A <= " -> " <= WORD_B <= "]"
          <= IO.newline() <= IO.newline();
    chout.flush();

0 => int count;

// 1) make first word WORD_A
emitWord( WORD_A, 0.0 );
pushRecent( WORD_A );
T_WORD => now;
1 => count;

// 2) generate middle words (leave last slot for WORD_B)
while( count < TOTAL_WORDS - 1 )
{
    // progress t through the middle: count 1..TOTAL_WORDS-2 -> 0..1
    Math.remap( count, 1, TOTAL_WORDS-2, 0.0, 1.0 ) => float t;

    // blended semantic vector for this moment
    blend( vecA, vecB, t, v );

    // retrieve candidates near blended vector
    model.getSimilar( v, cand.size(), cand );

    // line breaks
    if( count % WORDS_PER_LINE == 0 )
    {
        chout <= IO.newline(); chout.flush();
        chout <= "-------------morphing-------------" <= IO.newline(); chout.flush();
        playMorphing(); // call directly (not sporked) - it takes exactly 1 second
    }

    chooseNextWord(t) => string w;

    emitWord( w, t );
    pushRecent( w );

    T_WORD => now;
    count++;
}

// 3) make last word WORD_B
// if we just completed a line, print morphing line first
if( count % WORDS_PER_LINE == 0 )
{
    chout <= IO.newline(); chout.flush();
    chout <= "-------------morphing------------" <= IO.newline(); chout.flush();
    playMorphing();
}
// print WORD_B (on same line if line isn't full, or new line if it is)
emitWord( WORD_B, 1.0 );
chout <= IO.newline(); chout.flush();
T_WORD => now;

    chout <= IO.newline() <= "-- end --" <= IO.newline();
    chout.flush();
}

// main interactive loop

chout <= IO.newline()
      <= "\"Semantic Crossfade\" (Interactive)" <= IO.newline()
      <= IO.newline();
chout.flush();

// loop for multiple poems
while( true )
{
    // get WORD_A
    getWord( "Enter starting word (e.g., ocean) => " ) => string WORD_A;
    
    // get WORD_B
    getWord( "Enter ending word (e.g., machine) => " ) => string WORD_B;
    
    // generate the poem
    generatePoem( WORD_A, WORD_B );
    
    // ask if user wants to continue
    chout <= IO.newline() <= "Generate another poem? (y/n) => ";
    chout.flush();
    in.prompt( "" ) => now;
    
    string response;
    if( in.more() )
    {
        in.getLine().lower() => response;
        if( response == "n" || response == "no" )
        {
            break;
        }
    }
    
    chout <= IO.newline();
    chout.flush();
}
