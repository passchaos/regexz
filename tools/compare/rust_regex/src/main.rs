//! Rust `regex` side of the competitor comparison. Mirrors
//! tools/compare/zig_regex.zig. Run with `cargo run --release`.
use regex::{Regex, RegexSet};
use std::hint::black_box;
use std::time::Instant;

fn median(samples: &mut [f64]) -> f64 {
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    samples[samples.len() / 2]
}

fn bench_find(name: &str, pattern: &str, input: &str, iterations: usize) {
    let re = Regex::new(pattern).unwrap();
    for _ in 0..10 {
        black_box(re.find_iter(input).count());
    }
    let mut samples = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        let mut pieces = 0usize;
        for _ in 0..iterations {
            pieces += re.find_iter(input).count();
        }
        let ns = start.elapsed().as_nanos() as f64 / iterations as f64;
        black_box(pieces);
        samples.push(ns);
    }
    println!("{name:<40} {:>10.1} ns/iter", median(&mut samples));
}

fn bench_split(name: &str, pattern: &str, input: &str, iterations: usize) {
    let re = Regex::new(pattern).unwrap();
    for _ in 0..20 {
        black_box(re.split(input).collect::<Vec<_>>().len());
    }
    let mut samples = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        let mut pieces = 0usize;
        for _ in 0..iterations {
            pieces += re.split(input).collect::<Vec<_>>().len();
        }
        let ns = start.elapsed().as_nanos() as f64 / iterations as f64;
        black_box(pieces);
        samples.push(ns);
    }
    println!("{name:<40} {:>10.1} ns/iter", median(&mut samples));
}

fn bench_fullmatch(name: &str, pattern: &str, input: &str, iterations: usize) {
    let re = Regex::new(pattern).unwrap();
    for _ in 0..1000 {
        black_box(fullmatch(&re, input));
    }
    let mut samples = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        let mut hits = 0usize;
        for _ in 0..iterations {
            hits += usize::from(fullmatch(&re, input));
        }
        let ns = start.elapsed().as_nanos() as f64 / iterations as f64;
        black_box(hits);
        samples.push(ns);
    }
    println!("{name:<40} {:>10.1} ns/iter", median(&mut samples));
}

fn fullmatch(re: &Regex, input: &str) -> bool {
    re.find(input)
        .map_or(false, |m| m.start() == 0 && m.end() == input.len())
}

fn bench_replace(name: &str, pattern: &str, input: &str, substitution: &str, iterations: usize) {
    let re = Regex::new(pattern).unwrap();
    for _ in 0..100 {
        black_box(re.replace_all(input, substitution));
    }
    let mut samples = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        for _ in 0..iterations {
            black_box(re.replace_all(input, substitution));
        }
        let ns = start.elapsed().as_nanos() as f64 / iterations as f64;
        samples.push(ns);
    }
    println!("{name:<40} {:>10.1} ns/iter", median(&mut samples));
}

fn bench_set(name: &str, patterns: &[&str], input: &str, iterations: usize) {
    let set = RegexSet::new(patterns).unwrap();
    for _ in 0..10 {
        black_box(set.matches(input).into_iter().count());
    }
    let mut samples = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        let mut hits = 0usize;
        for _ in 0..iterations {
            hits += set.matches(input).into_iter().count();
        }
        let ns = start.elapsed().as_nanos() as f64 / iterations as f64;
        black_box(hits);
        samples.push(ns);
    }
    println!("{name:<40} {:>10.1} ns/iter", median(&mut samples));
}

fn bench_compile(name: &str, pattern: &str, iterations: usize) {
    let mut samples = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        for _ in 0..iterations {
            black_box(Regex::new(pattern).unwrap());
        }
        let ns = start.elapsed().as_nanos() as f64 / iterations as f64;
        samples.push(ns);
    }
    println!("{name:<40} {:>10.1} ns/iter", median(&mut samples));
}

fn main() {
    let sample = "Hello, world!  This is a test of the Qwen pre-tokenizer. Numbers 12345 and symbols !@#$%^&*() and Unicode 你好世界 café.\n";
    let ascii_text = sample.repeat(200);
    let cjk_text = "你好世界，这是一个中文分词测试。\n".repeat(4000);
    let html_text = "<div class=\"x\"><span>text</span></div> ".repeat(2000);
    let url_text = "see https://example.com/a/b?c=1 and http://x.y ".repeat(1500);
    let json_text = "{\"name\": \"value\", \"id\": 12345} ".repeat(400);
    let number_text = "x=-12.5 y=3 z=0.25 ".repeat(2000);
    let csv_text = "alpha,beta,gamma,delta,epsilon,".repeat(1000);
    let word_text = "alpha beta gamma delta epsilon ".repeat(3000);
    let replace_text = "aaa bbb aaa bbb ".repeat(2000);
    let greek_text = "αβγδε ζηθικ λμνξο ".repeat(2000);
    let email_text = "user.name@example.com ".repeat(800);
    let ip_text = "192.168.1.1 10.0.0.255 172.16.0.1 ".repeat(2000);
    let date_text = "2026-11-21 2025-01-05 1999-12-31 ".repeat(2000);
    let cafe_text = "café CAFÉ Café ".repeat(2000);
    let day_text = "sunday monday tuesday wednesday ".repeat(2000);
    let color_text = "#ff00aa #00FF00 #123456 ".repeat(2000);
    let version_text = "v1.2.3 10.0.0 v2.11.5 ".repeat(2000);
    let code_text = "int foo_1 = bar2; x = y_3; ".repeat(2000);
    let thousands_text = "1,234 12,345,678 999,000 ".repeat(2000);
    let domain_text = "www.example.com api.test.org sub.domain.net ".repeat(1500);
    let percent_text = "12.5% 100% 0.25% ".repeat(2000);
    let time_text = "12:34 23:59:59 07:08 ".repeat(2000);
    let uuid_text = "550e8400-e29b-41d4-a716-446655440000 123e4567-e89b-12d3-a456-426614174000 ".repeat(1000);
    let semver_text = "1.2.3-beta.1 10.0.0-rc.2 2.11.5 ".repeat(2000);
    let opt_text = "v1.2 2.3 v4.5 6.7 ".repeat(3000);
    let ab_text = "ababab abab ".repeat(4000);
    let camel_text = "fooBar bazQux helloWorld x ".repeat(3000);
    let kv_text = "name = value key=value a  =  b ".repeat(3000);
    let ipport_text = "192.168.1.1:8080 10.0.0.1:443 ".repeat(3000);
    let sign_text = "x=-12.5 y=+3 z=0.25 ".repeat(2000);
    let attr_text = "<div id=\"main\" class=\"box\">".repeat(2000);
    let md_text = "# Title\n## Section\ntext\n### Sub\n".repeat(1500);
    let prefix_text = "prefix postfix prefixx post ".repeat(3000);
    let mixed_text = "a bb ccc a bb ccc ".repeat(4000);
    let stamp_text = "2026-11-21T13:29:29 2025-01-05T00:00:00 ".repeat(2000);
    let unit_text = "12px 3.5em 100% 2rem ".repeat(2000);
    let call_text = "foo(1) bar_baz(x) qux () ".repeat(2000);
    let mac_text = "00:1A:2B:3C:4D:5E aa:bb:cc:dd:ee:ff ".repeat(2000);
    let b64_text = "SGVsbG8gV29ybGQhIFRoaXMgaXMgYSBiYXNlNjQgc3RyaW5nIQ== ".repeat(2000);
    let config_text = "name: value\n[section]\nkey = 1\n".repeat(2000);
    let template_text = "hello ${name} and ${user.id} ".repeat(2000);
    let path_text = "C:\\Users\\dev\\file.txt D:\\data\\x.csv ".repeat(2000);
    let css_text = ".button { color: red; } #main { margin: 0; } ".repeat(2000);
    let slash_text = "11/21/2026 01/05/2025 12/31/1999 ".repeat(2000);

    let qwen = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+";

    bench_compile("compile Qwen tokenizer", qwen, 500);
    bench_compile(
        "compile xDS-like",
        "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)",
        20000,
    );
    bench_find("find Qwen tokenizer", qwen, &ascii_text, 50);
    bench_find("findAll Qwen (borrowed)", qwen, &ascii_text, 50);
    bench_find("findAll Qwen (owning)", qwen, &ascii_text, 50);
    bench_find("find CJK tokenizer", qwen, &cjk_text, 50);
    bench_find("find HTML tag", "<[^>]+>", &html_text, 200);
    bench_find("find URL", "https?://[^\\s]+", &url_text, 200);
    bench_find("find JSON string literal", "\"[^\"]*\"", &json_text, 200);
    bench_find("find JSON number", "-?\\d+(?:\\.\\d+)?", &number_text, 200);
    bench_find("find word boundary", "(?-u:\\b\\w+\\b)", &word_text, 200);
    bench_find("find (?i) literal", "(?i)alpha", &word_text, 200);
    bench_find(
        "find alternation (5 words)",
        "alpha|gamma|epsilon|zeta|theta",
        &word_text,
        200,
    );
    bench_find("find (?i) alternation", "(?i)alpha|gamma", &word_text, 200);
    bench_find(
        "find 10-word alternation",
        "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa",
        &word_text,
        200,
    );
    bench_find("find Greek class", "\\p{Script=Greek}+", &greek_text, 200);
    bench_find("find prefix+suffix", "\\w+@example\\.com", &email_text, 200);
    bench_replace(
        "replaceAll email captures",
        "(\\w+)@(\\w+)\\.com",
        &email_text,
        "$2@$1",
        200,
    );
    bench_find("find IPv4", "\\d{1,3}(?:\\.\\d{1,3}){3}", &ip_text, 200);
    bench_find("find date", "\\d{4}-\\d{2}-\\d{2}", &date_text, 200);
    bench_find(
        "find 20-word alternation",
        "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon",
        &word_text,
        200,
    );
    bench_find("find anchored line", "(?m)^\\w+", &ascii_text, 200);
    bench_find("find (?i) Unicode literal", "(?i)café", &cafe_text, 200);
    bench_find(
        "find shared-prefix alternation",
        "sunday|saturday|someday",
        &day_text,
        200,
    );
    bench_find("find one-char alternation", "a|b|c", &ascii_text, 200);
    bench_find("find hex color", "#[0-9a-fA-F]{6}", &color_text, 200);
    bench_find(
        "find version",
        "v?\\d+\\.\\d+\\.\\d+",
        &version_text,
        200,
    );
    bench_find("find nullable prefix", ".*test", &ascii_text, 200);
    bench_find("find identifier", "[A-Za-z_]\\w*", &code_text, 200);
    bench_find("find thousands", "\\d{1,3}(?:,\\d{3})+", &thousands_text, 200);
    bench_find(
        "find domain",
        "[a-z0-9-]+(?:\\.[a-z0-9-]+)+",
        &domain_text,
        200,
    );
    bench_find("find percent", "\\d+(?:\\.\\d+)?%", &percent_text, 200);
    bench_find("find time", "\\d{1,2}:\\d{2}(?::\\d{2})?", &time_text, 200);
    bench_find("find end-anchored word", "(?m)\\w+$", &ascii_text, 200);
    bench_find(
        "find UUID",
        "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        &uuid_text,
        200,
    );
    bench_find(
        "find semver",
        "\\d+\\.\\d+\\.\\d+-[0-9A-Za-z.-]+",
        &semver_text,
        200,
    );
    bench_find(
        "find email TLD",
        "\\w+@\\w+\\.(?:com|org|net)",
        &email_text,
        200,
    );
    bench_find(
        "find CIDR",
        "\\d{1,3}(?:\\.\\d{1,3}){3}(?:/\\d{1,2})?",
        &ip_text,
        200,
    );
    bench_find("find line full", "(?m)^.*$", &ascii_text, 200);
    bench_find("find optional prefix run", "v?\\w+", &opt_text, 200);
    bench_find("find repeated literal group", "(?:ab)+", &ab_text, 200);
    bench_find("find camelCase", "[a-z]+[A-Z][a-z]+", &camel_text, 200);
    bench_find("find key-value", "\\w+\\s*=\\s*\\w+", &kv_text, 200);
    bench_find(
        "find IP port",
        "\\d+\\.\\d+\\.\\d+\\.\\d+:\\d+",
        &ipport_text,
        200,
    );
    bench_find("find (?i) class", "(?i)[a-z]+", &ascii_text, 200);
    bench_find("find prefix alternation", "(?:pre|post)fix", &prefix_text, 200);
    bench_find(
        "find signed number",
        "[+-]?\\d+(?:\\.\\d+)?",
        &sign_text,
        200,
    );
    bench_find(
        "find html attribute",
        "\\w+=\"[^\"]*\"",
        &attr_text,
        200,
    );
    bench_find("find markdown heading", "(?m)^#{1,6} .*$", &md_text, 200);
    bench_find("find mixed alternation", "a|bb|ccc", &mixed_text, 200);
    bench_find("find capitalized words", r"\b[A-Z][a-z]+\b", &word_text, 200);
    bench_find("find markdown list", r"(?m)^\s*[-*+] ", &md_text, 200);
    bench_find("find JSON escaped string", r#""(?:\\.|[^"\\])*""#, &json_text, 200);
    bench_find("find double spaces", r"\s{2,}", &ascii_text, 200);
    bench_find("find log level", "(?i)error|warn|info", &ascii_text, 200);
    bench_find("find markdown heading ws", r"(?m)^#{1,6}\s+.*$", &md_text, 200);
    bench_find("find markdown list ws", r"(?m)^\s*[-*+]\s+", &md_text, 200);
    bench_find("find escaped string loop", r#""[^"\\]*(?:\\.[^"\\]*)*""#, &json_text, 200);
    bench_find("find HTTP methods", r"(?i)\b(?:get|post|put|delete)\b", &ascii_text, 200);
    bench_find("find full email", r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", &email_text, 200);
    bench_find("find blank lines", r"(?m)^\s*$", &ascii_text, 200);
    bench_find("find floats", r"\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", &number_text, 200);
    bench_find("find currency", r"\$\d+(?:\.\d{2})?", &number_text, 200);
    bench_find(
        "find ISO timestamp",
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}",
        &stamp_text,
        200,
    );
    bench_find("find JSON key", r#""[^"]+"\s*:"#, &json_text, 200);
    bench_find("find HTML comment", r"<!--[\s\S]*?-->", &html_text, 200);
    bench_find("find hashtag", r"#\w+", &ascii_text, 200);
    bench_find("find mention", r"@\w+", &ascii_text, 200);
    bench_find("find CSS unit", r"\d+(?:px|em|rem|%)", &unit_text, 200);
    bench_find("find function call", r"[A-Za-z_]\w*\s*\(", &call_text, 200);
    bench_find(
        "find SQL keyword",
        r"(?i)\b(?:select|from|where|join)\b",
        &ascii_text,
        200,
    );
    bench_find("find JSON literal", r"\b(?:true|false|null)\b", &json_text, 200);
    bench_find("find blockquote", r"(?m)^>.*$", &md_text, 200);
    bench_find("find ordered list", r"(?m)^\d+\.\s", &md_text, 200);
    bench_find("find query param", r"[?&]\w+=", &url_text, 200);
    bench_find(
        "find MAC address",
        r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}",
        &mac_text,
        200,
    );
    bench_find("find base64 run", r"[A-Za-z0-9+/]{20,}", &b64_text, 200);
    bench_find("find markdown link", r"\[[^\]]+\]\([^)]+\)", &md_text, 200);
    bench_find("find YAML key", r"(?m)^\s*[\w-]+:", &config_text, 200);
    bench_find("find TOML table", r"(?m)^\[[\w.]+\]$", &config_text, 200);
    bench_find("find template", r"\$\{[^}]+\}", &template_text, 200);
    bench_find(
        "find Windows path",
        r#"[A-Za-z]:\\[^:*?"<>|]+"#,
        &path_text,
        200,
    );
    bench_find("find CSS selector", r"[.#][\w-]+\s*\{", &css_text, 200);
    bench_find("find slash date", r"\d{2}/\d{2}/\d{4}", &slash_text, 200);
    bench_find(
        "find HTTP request",
        r"(?:GET|POST) /[^ ]+ HTTP/1\.[01]",
        &ascii_text,
        200,
    );
    bench_split("split whitespace (22 KiB)", "\\s+", &ascii_text, 200);
    bench_split("split commas (29 KiB)", ",", &csv_text, 200);
    bench_fullmatch(
        "fullmatch literal",
        "hello, world!",
        "hello, world!",
        200000,
    );
    bench_fullmatch("fullmatch class", "[A-Za-z0-9._-]+", "User.Name_42", 200000);
    bench_fullmatch(
        "fullmatch xDS-like",
        "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)",
        "/demo.Service/Get",
        200000,
    );
    bench_replace("replaceAll a+ -> x", "a+", &replace_text, "x", 200);
    bench_replace("replaceAll \\A|\\z -> X", "\\A|\\z", &ascii_text, "X", 200);

    let set_patterns = [
        "[a-z]+@", "[a-z]+#", "[a-z]+%", "[a-z]+&", "[a-z]+!", "[a-z]+~", "[a-z]+`", "[a-z]+;",
        "[a-z]+:",
    ];
    bench_set(
        "RegexSet 9 no-match patterns",
        &set_patterns,
        &ascii_text,
        200,
    );
}
