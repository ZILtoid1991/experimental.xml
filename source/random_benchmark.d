
module random_benchmark;

import genxml;
import std.experimental.statistical;

import std.experimental.xml.lexers;
import std.experimental.xml.parser;
import std.experimental.xml.cursor;

import std.array;
import std.stdio;
import std.file;
import std.path: buildPath, exists;
import std.conv;
import core.time: Duration, nsecs;

// BENCHMARK CONFIGURATIONS: TWEAK AS NEEDED
enum BenchmarkConfig theBenchmark = {
    components: [
        "Parser_SliceLexer": ComponentConfig("to!string", "parserTest!SliceLexer"),
        "Parser_RangeLexer": ComponentConfig("to!string", "parserTest!RangeLexer"),
        "Cursor_SliceLexer": ComponentConfig("to!string", "cursorTest!SliceLexer"),
        "Cursor_RangeLexer": ComponentConfig("to!string", "cursorTest!RangeLexer"),
    ],
    configurations: [
        "M10": M10,
        "M100": M100,
    ],
};

enum GenXmlConfig M100 = { minDepth:         6,
                           maxDepth:        14,
                           minChilds:        3,
                           maxChilds:        9,
                           minAttributeNum:  0,
                           maxAttributeNum:  5};

enum GenXmlConfig M10 = { minDepth:         5,
                          maxDepth:        13,
                          minChilds:        3,
                          maxChilds:        8,
                          minAttributeNum:  0,
                          maxAttributeNum:  4};

// FUNCTIONS USED FOR TESTING

void parserTest(alias Lexer)(string data)
{
    auto parser = Parser!(Lexer!string)();
    parser.setSource(data);
    foreach(e; parser)
    {
        doNotOptimize(e);
    }
}

void cursorTest(alias Lexer)(string data)
{
    auto cursor = XMLCursor!(Parser!(Lexer!string))();
    cursor.setSource(data);
    inspectOneLevel(cursor);
}

void doNotOptimize(T)(auto ref T result)
{
    import std.process: thisProcessID;
    if (thisProcessID == 1)
        writeln(result);
}

void inspectOneLevel(T)(ref T cursor)
{
    do
    {
        doNotOptimize(cursor.getAttributes());
        if (cursor.hasChildren())
        {
            cursor.enter();
            inspectOneLevel(cursor);
            cursor.exit();
        }
    }
    while (cursor.next());
}

// MAIN TEST DRIVER
void main()
{
    stderr.writeln("Generating test files...");
    auto stats = generateTestFiles(theBenchmark);
    stderr.writeln("\nPerforming tests...");
    auto results = performBenchmark!theBenchmark;
    stderr.writeln();
    printResultsByConfiguration(theBenchmark, stats, results);
    writeln("\n If you are watching this on a terminal, you are encouraged to redirect the standard output to a file instead.\n");
}

// STRUCTURES HOLDING PARAMETERS AND RESULTS

struct BenchmarkConfig
{
    uint runsPerFile = 5;
    uint filesPerConfig = 3;
    ComponentConfig[string] components;
    GenXmlConfig[string] configurations;
}

struct ComponentConfig
{
    string inputFunction;
    string benchmarkFunction;
}

struct ComponentResults
{
    PreciseStatisticData!double speedStat;
    ConfigResults[string] configResults;
}

struct ConfigResults
{
    PreciseStatisticData!double speedStat;
    FileResults[string] fileResults;
}

struct FileResults
{
    PreciseStatisticData!(((long x) => nsecs(x)), (Duration d) => d.total!"nsecs") timeStat;
    PreciseStatisticData!double speedStat;
    Duration[] times;
    double[] speeds;
}

// CODE FOR TESTING

mixin template BenchmarkFunctions(string[] keys, ComponentConfig[] vals, size_t pos = 0)
{
    mixin("auto " ~ keys[pos] ~ "_BenchmarkFunction(string data) {"
            "import core.time: MonoTime;"
            "auto input = " ~ vals[pos].inputFunction ~ "(data);"
            "MonoTime before = MonoTime.currTime;"
            ~ vals[pos].benchmarkFunction ~ "(input);"
            "MonoTime after = MonoTime.currTime;"
            "return after - before;"
            "}"
        );
            
    static if (pos + 1 < keys.length)
        mixin BenchmarkFunctions!(keys, vals, pos + 1);
}

auto performBenchmark(BenchmarkConfig benchmark)()
{
    import std.meta;

    mixin BenchmarkFunctions!(benchmark.components.keys, benchmark.components.values);
    
    total_tests = benchmark.runsPerFile * benchmark.filesPerConfig * benchmark.configurations.length * benchmark.components.length;
    ComponentResults[string] results;
    foreach(component; aliasSeqOf!(benchmark.components.keys))
        results[component] = testComponent(benchmark, mixin("&" ~ component ~ "_BenchmarkFunction"));
        
    return results;
}

auto testComponent(BenchmarkConfig benchmark, Duration delegate(string) fun)
{
    import std.algorithm: map, joiner;
    
    ComponentResults results;
    foreach (config; benchmark.configurations.byKey)
        results.configResults[config] = testConfiguration(config, benchmark.filesPerConfig, benchmark.runsPerFile, fun);
    
    results.speedStat = PreciseStatisticData!double(results.configResults.byValue.map!"a.fileResults.byValue".joiner.map!"a.speeds".joiner);
    return results;
}

auto testConfiguration(string config, uint files, uint runs, Duration delegate(string) fun)
{
    import std.algorithm: map, joiner;
    
    ConfigResults results;
    foreach (filename; getConfigFiles(config, files))
        results.fileResults[filename] = testFile(filename, runs, fun);
        
    results.speedStat = PreciseStatisticData!double(results.fileResults.byValue.map!"a.speeds".joiner);
    return results;
}

ulong total_tests;
ulong performed_tests;
auto testFile(string name, uint runs, Duration delegate(string) fun)
{
    FileResults results;
    foreach (run; 0..runs)
    {
        auto time = fun(readText(name));
        results.times ~= time;
        results.speeds ~= (cast(double)getSize(name)) / time.total!"usecs";
        stderr.writef("\r%d out of %d tests performed", ++performed_tests, total_tests);
    }
    results.timeStat = typeof(results.timeStat)(results.times);
    results.speedStat = PreciseStatisticData!double(results.speeds);
    return results;
}

string[] getConfigFiles(string config, uint maxFiles)
{
    string[] results = [];
    int count = 1;
    while(count <= maxFiles && buildPath("random-benchmark", config ~ "_" ~ to!string(count)).exists)
    {
        results ~= buildPath("random-benchmark", config ~ "_" ~ to!string(count));
        count++;
    }
    return results;
}

auto generateTestFiles(BenchmarkConfig benchmark)
{
    if(!exists("random-benchmark"))
        mkdir("random-benchmark");

    FileStats[string] results;
        
    total_files = benchmark.filesPerConfig * benchmark.configurations.length;
    foreach (config; benchmark.configurations.byKeyValue)
        results.merge!"a"(generateTestFiles(config.value, config.key, benchmark.filesPerConfig));
        
    return results;
}

ulong total_files;
ulong generated_files;
auto generateTestFiles(GenXmlConfig config, string name, int count)
{
    FileStats[string] results;

    foreach (i; 0..count)
    {
        auto filename = buildPath("random-benchmark", name ~ "_" ~ to!string(i+1));
        if(!filename.exists)
        {
            auto file = File(filename, "w");
            results[filename] = genDocument(file.lockingTextWriter, config);
        }
        else
            results[filename] = FileStats.init;
        stderr.writef("\r%d out of %d files generated", ++generated_files, total_files);
    }
    return results;
}

void merge(alias f, V, K)(ref V[K] first, const V[K] second)
{
    import std.functional: binaryFun;
    alias fun = binaryFun!f;
    
    foreach (kv; second.byKeyValue)
        if (kv.key in first)
            first[kv.key] = fun(first[kv.key], kv.value);
        else
            first[kv.key] = kv.value;
}

// CODE FOR PRETTY PRINTING

string center(string str, ulong totalSpace)
{
    Appender!string result;
    auto whiteSpace = totalSpace - str.length;
    ulong before = whiteSpace / 2;
    foreach (i; 0..before)
        result.put(' ');
    result.put(str);
    foreach (i; before..whiteSpace)
        result.put(' ');
    return result.data;
}

Duration round(string unit)(Duration d)
{
    import core.time: dur;
    return dur!unit(d.total!unit);
}

void printTimesForConfiguration(BenchmarkConfig benchmark, ComponentResults[string] results, string config)
{
    import std.algorithm: max, map, minCount;
    import std.range: repeat, take;
    auto component_width = max(results.byKey.map!"a.length".minCount[0], 8);
    auto std_width = 16;
    auto big_width = 24;
    
    string formatDuration(Duration d)
    {
        import std.format: format;
        auto millis = d.total!"msecs";
        if (millis < 1000)
            return format("%3u ms", millis);
        else if (millis < 10000)
            return format("%.2f  s", millis/1000.0);
        else if (millis < 100000)
            return format("%.1f  s", millis/1000.0);
        else
            return to!string(millis/1000) ~ " s";
    }
    
    foreach (component; results.byKey)
    {
        write("\r  " , component, ":");
        foreach (file; config.getConfigFiles(benchmark.filesPerConfig))
        {
            auto res = results[component].configResults[config].fileResults[file].timeStat;
            write(center("min: " ~ formatDuration(res.min), std_width));
            write(center("max: " ~ formatDuration(res.max), std_width));
            write(center("avg: " ~ formatDuration(res.mean), std_width));
            writeln(center("deviation: " ~ formatDuration(res.deviation), big_width));
            write(repeat(' ').take(component_width+3));
        }
    }
    writeln();
}

void printSpeedsForConfiguration(BenchmarkConfig benchmark, ComponentResults[string] results, string config)
{
    import std.range: repeat, take;
    import std.algorithm: max, map, minCount;
    import std.format: format;

    auto component_width = max(results.byKey.map!"a.length".minCount[0], 13);
    auto speed_column_width = 8UL;
    auto spaces = repeat(' ');
    auto lines = repeat('-');
    auto boldLines = repeat('=');
    write(spaces.take(component_width));
    foreach (i; 0..benchmark.filesPerConfig)
    {
        write("|");
        write(center("file " ~ to!string(i+1), 3*speed_column_width + 2));
    }
    writeln();
    write(center("Speeds (MB/s)", component_width));
    foreach (i; 0..benchmark.filesPerConfig)
    {
        write("|");
        write(lines.take(3*speed_column_width + 2));
    }
    writeln();
    write(spaces.take(component_width));
    foreach (i; 0..benchmark.filesPerConfig)
    {
        write("|");
        write(center("min", speed_column_width));
        write("|");
        write(center("avg", speed_column_width));
        write("|");
        write(center("max", speed_column_width));
    }
    writeln();
    foreach (component; results.byKey)
    {
        writeln(boldLines.take(component_width + benchmark.filesPerConfig*(3 + 3*speed_column_width)));
        write(spaces.take(component_width));
        foreach (file; getConfigFiles(config, benchmark.filesPerConfig))
        {
            auto fres = results[component].configResults[config].fileResults[file];
            write("|");
            write(center(format("%6.2f", fres.speedStat.min), speed_column_width));
            write("|");
            write(center(format("%6.2f", fres.speedStat.mean), speed_column_width));
            write("|");
            write(center(format("%6.2f", fres.speedStat.max), speed_column_width));
        }
        writeln();
        write(center(component, component_width));
        foreach (i; 0..benchmark.filesPerConfig)
        {
            write("|");
            write(lines.take(3*speed_column_width + 2));
        }
        writeln();
        write(spaces.take(component_width));
        foreach (file; getConfigFiles(config, benchmark.filesPerConfig))
        {
            auto fres = results[component].configResults[config].fileResults[file];
            write("|");
            write(center(format("deviation: %6.2f", fres.speedStat.deviation), 3*speed_column_width + 2));
        }
        writeln();
    }
}

void printFilesForConfiguration(string config, uint maxFiles, FileStats[string] filestats)
{
    import std.algorithm: each, map, max, maxCount;
    import std.path: pathSplitter, stripExtension;
    import std.file: getSize;
    
    ulong columnWidth = 16;
    
    void writeSized(ulong value, string measure = " ")
    {
        import std.format: format;
        import std.range: repeat, take;
        import std.math: ceil, log10;
        
        string formatted;
        if (!value)
        {
            formatted = "  0 ";
        }
        else
        {
            static immutable string[] order = [" ", " k", " M", " G", " T"];
            auto lg = cast(int)ceil(log10(value));
            auto dec = (lg%3 == 0)? 0 : 3 - lg%3;
            auto ord = (lg-1)/3;
            auto val = value/(1000.0^^ord);
            auto fmt = (dec?"":" ") ~ "%." ~ to!string(dec) ~ "f";
            formatted = format(fmt, val) ~ order[ord];
        }
        formatted ~= measure;
        formatted.center(columnWidth).write;
    }
    
    write("                     ");
    foreach(name; config.getConfigFiles(maxFiles))
        name.pathSplitter.back.stripExtension.center(columnWidth).write;
        
    write("\n  total file size:   ");
    foreach(name; config.getConfigFiles(maxFiles))
        writeSized(name.getSize(), "B");
        
    write("\n  raw text content:  ");
    foreach(name; config.getConfigFiles(maxFiles))
        if (filestats[name] != FileStats.init)
            writeSized(filestats[name].textChars, "B");
        else
            center("-", columnWidth).write;
        
    write("\n  useless spacing:   ");
    foreach(name; config.getConfigFiles(maxFiles))
        if (filestats[name] != FileStats.init)
            writeSized(filestats[name].spaces, "B");
        else
            center("-", columnWidth).write;
            
    write("\n  total nodes:       ");
    foreach(name; config.getConfigFiles(maxFiles))
        if (filestats[name] != FileStats.init)
        {
            auto stat = filestats[name];
            auto total = stat.elements + stat.textNodes + stat.cdataNodes + stat.processingInstructions + stat.comments + stat.attributes;
            writeSized(total);
        }
        else
            center("-", columnWidth).write;
            
    write("\n  element nodes:     ");
    foreach(name; config.getConfigFiles(maxFiles))
        if (filestats[name] != FileStats.init)
            writeSized(filestats[name].elements);
        else
            center("-", columnWidth).write;
            
    write("\n  attribute nodes:   ");
    foreach(name; config.getConfigFiles(maxFiles))
        if (filestats[name] != FileStats.init)
            writeSized(filestats[name].attributes);
        else
            center("-", columnWidth).write;
            
    write("\n  text nodes:        ");
    foreach(name; config.getConfigFiles(maxFiles))
        if (filestats[name] != FileStats.init)
            writeSized(filestats[name].textNodes);
        else
            center("-", columnWidth).write;
            
    write("\n  cdata nodes:       ");
    foreach(name; config.getConfigFiles(maxFiles))
        if (filestats[name] != FileStats.init)
            writeSized(filestats[name].cdataNodes);
        else
            center("-", columnWidth).write;
            
    write("\n  comment nodes:     ");
    foreach(name; config.getConfigFiles(maxFiles))
        if (filestats[name] != FileStats.init)
            writeSized(filestats[name].comments);
        else
            center("-", columnWidth).write;
    writeln();
}

void printResultsByConfiguration(BenchmarkConfig benchmark, FileStats[string] filestats, ComponentResults[string] results)
{
    uint i = 1;
    foreach (config; benchmark.configurations.byKey)
    {
        writeln("\n=== CONFIGURATION " ~ to!string(i) ~ ": " ~ config ~ " ===\n");
        writeln("Timings:\n");
        printTimesForConfiguration(benchmark, results, config);
        writeln("Speeds:\n");
        printSpeedsForConfiguration(benchmark, results, config);
        writeln("\nConfiguration Parameters:");
        benchmark.configurations[config].prettyPrint(2).writeln;
        writeln("\nFile Statistics (only for newly created files):");
        printFilesForConfiguration(config, benchmark.filesPerConfig, filestats);
    }
}