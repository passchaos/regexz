//! Rust `regex` side of the competitor comparison. Mirrors
//! tools/compare/zig_regex.zig. Run with `cargo run --release`.
use regex::Regex;
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

    let qwen = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+";

    bench_compile("compile Qwen tokenizer", qwen, 500);
    bench_find("find Qwen tokenizer", qwen, &ascii_text, 50);
    bench_find("find CJK tokenizer", qwen, &cjk_text, 50);
    bench_find("find HTML tag", "<[^>]+>", &html_text, 200);
    bench_find("find URL", "https?://[^\\s]+", &url_text, 200);
    bench_find("find JSON string literal", "\"[^\"]*\"", &json_text, 200);
    bench_find("find JSON number", "-?\\d+(?:\\.\\d+)?", &number_text, 200);
}
