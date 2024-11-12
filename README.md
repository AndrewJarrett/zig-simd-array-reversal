## Zig SIMD Array Reversal Testing
The goal of this is to explore using SIMD in Zig for reversing arrays of unsigned integers. 
To run tests:
```bash
zig test src/main.zig
```
In order to build and run the basic benchmark:
```bash
zig build --release=fast && zig-out/bin/zig-simd-array-reversal
```
Currently, it appears that the basic algorithm works the best with the xor reversal and the SIMD reversal being close, but consistently slower than the approach using a temp variable. I'm not sure yet why the SIMD version is slower, 
but it could have to do with using the Zig builtin `@memcpy` - perhaps this is a basic O(n) copy of the reversed chunks into memory which means the total algorithm is O(n + c) where c is the time taken by the SIMD operations.

## Example Benchmark Run
Here is an example run of the benchmarks showing the timing of the different algorithms.
```test
Use 'zig test src/main.zig' in order to run tests.

Now performing basic benchmarks... Please build using 'zig build --release=fast'.

Test basic reversal with 1,000,000 elements...
Total time: 1462 ms
Test xor reversal with 1,000,000 elements...
Total time: 1841 ms
Test SIMD reversal with 1,000,000 elements...
Total time: 2370 ms
```

However, these results don't always seem to be consistent and a better benchmarking tool is likely needed to determine which version is better.
