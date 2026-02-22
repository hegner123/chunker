package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	randv2 "math/rand/v2"
	"os"
	"strconv"
	"time"
)

// Config is the top-level schema configuration.
type Config struct {
	Lines int        `json:"lines"`
	Keys  []FieldDef `json:"keys"`
}

// FieldDef describes a single field and its generation parameters.
type FieldDef struct {
	Name      string   `json:"name"`
	Type      string   `json:"type"`
	Values    []string `json:"values,omitempty"`
	Length    int      `json:"length,omitempty"`
	Min       *float64 `json:"min,omitempty"`
	Max       *float64 `json:"max,omitempty"`
	Precision *int     `json:"precision,omitempty"`
	Start     string   `json:"start,omitempty"`
	Interval  string   `json:"interval,omitempty"`
}

func main() {
	configPath := flag.String("config", "", "path to schema config JSON file (required)")
	linesOverride := flag.Int("lines", 0, "number of lines to generate (overrides config)")
	outputPath := flag.String("output", "", "output file path (default: stdout)")
	seed := flag.Uint64("seed", 0, "random seed for reproducibility (0 = random)")
	flag.Parse()

	if *configPath == "" {
		fmt.Fprintf(os.Stderr, "error: --config is required\n")
		os.Exit(1)
	}

	configData, err := os.ReadFile(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error reading config: %v\n", err)
		os.Exit(1)
	}

	var cfg Config
	if err := json.Unmarshal(configData, &cfg); err != nil {
		fmt.Fprintf(os.Stderr, "error parsing config: %v\n", err)
		os.Exit(1)
	}

	if *linesOverride > 0 {
		cfg.Lines = *linesOverride
	}
	if cfg.Lines <= 0 {
		fmt.Fprintf(os.Stderr, "error: lines must be > 0\n")
		os.Exit(1)
	}

	if err := validateConfig(&cfg); err != nil {
		fmt.Fprintf(os.Stderr, "config validation error: %v\n", err)
		os.Exit(1)
	}

	var rng *randv2.Rand
	if *seed != 0 {
		rng = randv2.New(randv2.NewPCG(*seed, *seed))
	} else {
		rng = randv2.New(randv2.NewPCG(randv2.Uint64(), randv2.Uint64()))
	}

	generators, err := buildGenerators(cfg.Keys, rng)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error building generators: %v\n", err)
		os.Exit(1)
	}

	var out *os.File
	if *outputPath != "" {
		out, err = os.Create(*outputPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error creating output file: %v\n", err)
			os.Exit(1)
		}
		defer out.Close()
	} else {
		out = os.Stdout
	}

	w := bufio.NewWriterSize(out, 64*1024)

	for i := range cfg.Lines {
		row := make(map[string]any, len(cfg.Keys))
		for j, gen := range generators {
			row[cfg.Keys[j].Name] = gen(i)
		}

		line, merr := json.Marshal(row)
		if merr != nil {
			fmt.Fprintf(os.Stderr, "error marshaling line %d: %v\n", i, merr)
			os.Exit(1)
		}

		if _, werr := w.Write(line); werr != nil {
			fmt.Fprintf(os.Stderr, "error writing line %d: %v\n", i, werr)
			os.Exit(1)
		}
		if werr := w.WriteByte('\n'); werr != nil {
			fmt.Fprintf(os.Stderr, "error writing newline: %v\n", werr)
			os.Exit(1)
		}
	}

	if err := w.Flush(); err != nil {
		fmt.Fprintf(os.Stderr, "error flushing output: %v\n", err)
		os.Exit(1)
	}

	if *outputPath != "" {
		if err := out.Close(); err != nil {
			fmt.Fprintf(os.Stderr, "error closing output file: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "wrote %d lines to %s\n", cfg.Lines, *outputPath)
	}
}

func validateConfig(cfg *Config) error {
	if len(cfg.Keys) == 0 {
		return fmt.Errorf("keys array is empty")
	}
	seen := make(map[string]bool, len(cfg.Keys))
	for _, f := range cfg.Keys {
		if f.Name == "" {
			return fmt.Errorf("field has empty name")
		}
		if seen[f.Name] {
			return fmt.Errorf("duplicate field name: %q", f.Name)
		}
		seen[f.Name] = true

		switch f.Type {
		case "uuid", "boolean", "null":
			// no extra params needed
		case "timestamp":
			if f.Start != "" {
				if _, err := time.Parse(time.RFC3339, f.Start); err != nil {
					return fmt.Errorf("field %q: invalid start time: %v", f.Name, err)
				}
			}
			if f.Interval != "" {
				if _, err := parseDuration(f.Interval); err != nil {
					return fmt.Errorf("field %q: invalid interval: %v", f.Name, err)
				}
			}
		case "enum":
			if len(f.Values) == 0 {
				return fmt.Errorf("field %q: enum type requires non-empty values array", f.Name)
			}
		case "string":
			if f.Length < 0 {
				return fmt.Errorf("field %q: string length must be >= 0", f.Name)
			}
		case "integer":
			if f.Min != nil && f.Max != nil && *f.Min > *f.Max {
				return fmt.Errorf("field %q: min (%v) > max (%v)", f.Name, *f.Min, *f.Max)
			}
		case "float":
			if f.Min != nil && f.Max != nil && *f.Min > *f.Max {
				return fmt.Errorf("field %q: min (%v) > max (%v)", f.Name, *f.Min, *f.Max)
			}
		default:
			return fmt.Errorf("field %q: unknown type %q", f.Name, f.Type)
		}
	}
	return nil
}

// generator is a function that takes the line index and returns a value.
type generator func(lineIndex int) any

func buildGenerators(fields []FieldDef, rng *randv2.Rand) ([]generator, error) {
	gens := make([]generator, len(fields))
	for i, f := range fields {
		gen, err := makeGenerator(f, rng)
		if err != nil {
			return nil, fmt.Errorf("field %q: %w", f.Name, err)
		}
		gens[i] = gen
	}
	return gens, nil
}

func makeGenerator(f FieldDef, rng *randv2.Rand) (generator, error) {
	switch f.Type {
	case "uuid":
		return func(_ int) any { return generateUUID(rng) }, nil

	case "timestamp":
		start := time.Now().UTC()
		if f.Start != "" {
			parsed, err := time.Parse(time.RFC3339, f.Start)
			if err != nil {
				return nil, fmt.Errorf("invalid start: %w", err)
			}
			start = parsed.UTC()
		}
		interval := time.Second
		if f.Interval != "" {
			d, err := parseDuration(f.Interval)
			if err != nil {
				return nil, fmt.Errorf("invalid interval: %w", err)
			}
			interval = d
		}
		return func(lineIndex int) any {
			t := start.Add(time.Duration(lineIndex) * interval)
			if t.Nanosecond() == 0 {
				return t.Format(time.RFC3339)
			}
			// Trim trailing zeros from fractional seconds for clean output.
			return trimTrailingZeros(t.Format(time.RFC3339Nano))
		}, nil

	case "enum":
		values := f.Values
		return func(_ int) any {
			return values[rng.IntN(len(values))]
		}, nil

	case "string":
		length := 16
		if f.Length > 0 {
			length = f.Length
		}
		return func(_ int) any { return generateHexString(rng, length) }, nil

	case "integer":
		minVal := 0
		maxVal := 1000
		if f.Min != nil {
			minVal = int(*f.Min)
		}
		if f.Max != nil {
			maxVal = int(*f.Max)
		}
		rangeSize := maxVal - minVal + 1
		return func(_ int) any {
			return minVal + rng.IntN(rangeSize)
		}, nil

	case "float":
		minVal := 0.0
		maxVal := 1.0
		if f.Min != nil {
			minVal = *f.Min
		}
		if f.Max != nil {
			maxVal = *f.Max
		}
		precision := 2
		if f.Precision != nil {
			precision = *f.Precision
		}
		fmtStr := "%." + strconv.Itoa(precision) + "f"
		return func(_ int) any {
			v := minVal + rng.Float64()*(maxVal-minVal)
			// Round to requested precision by formatting and parsing back.
			// This ensures the JSON output has the exact decimal places requested.
			s := fmt.Sprintf(fmtStr, v)
			rounded, _ := strconv.ParseFloat(s, 64)
			return rounded
		}, nil

	case "boolean":
		return func(_ int) any {
			return rng.IntN(2) == 1
		}, nil

	case "null":
		return func(_ int) any {
			return nil
		}, nil

	default:
		return nil, fmt.Errorf("unknown type %q", f.Type)
	}
}

// generateUUID produces a random v4 UUID string using the provided RNG.
func generateUUID(rng *randv2.Rand) string {
	var buf [16]byte
	fillRandom(rng, buf[:])
	// Set version 4 and variant bits per RFC 4122.
	buf[6] = (buf[6] & 0x0f) | 0x40
	buf[8] = (buf[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		buf[0:4], buf[4:6], buf[6:8], buf[8:10], buf[10:16])
}

// generateHexString produces a random hex string of the given length.
func generateHexString(rng *randv2.Rand, length int) string {
	nBytes := (length + 1) / 2
	buf := make([]byte, nBytes)
	fillRandom(rng, buf)
	return hex.EncodeToString(buf)[:length]
}

// fillRandom fills buf with random bytes from the provided RNG.
func fillRandom(rng *randv2.Rand, buf []byte) {
	for i := 0; i < len(buf); i += 8 {
		v := rng.Uint64()
		for j := range min(8, len(buf)-i) {
			buf[i+j] = byte(v >> (j * 8))
		}
	}
}

// trimTrailingZeros removes unnecessary trailing zeros from RFC3339Nano timestamps.
// "2024-01-01T00:00:00.100000000Z" -> "2024-01-01T00:00:00.1Z"
func trimTrailingZeros(s string) string {
	if len(s) == 0 || s[len(s)-1] != 'Z' {
		return s
	}
	// Strip trailing Z, trim zeros, strip trailing dot if present, re-add Z.
	body := s[:len(s)-1]
	for len(body) > 0 && body[len(body)-1] == '0' {
		body = body[:len(body)-1]
	}
	if len(body) > 0 && body[len(body)-1] == '.' {
		body = body[:len(body)-1]
	}
	return body + "Z"
}

// parseDuration handles Go's time.ParseDuration plus "ms" shorthand already
// supported natively. It also handles bare integers as seconds.
func parseDuration(s string) (time.Duration, error) {
	// Try standard Go duration parsing first (supports "1s", "100ms", "1m30s", etc.)
	if d, err := time.ParseDuration(s); err == nil {
		return d, nil
	}
	// Try bare integer as seconds.
	if n, err := strconv.Atoi(s); err == nil {
		return time.Duration(n) * time.Second, nil
	}
	return 0, fmt.Errorf("cannot parse duration %q (use Go duration syntax: 1s, 100ms, 1m30s, etc.)", s)
}

