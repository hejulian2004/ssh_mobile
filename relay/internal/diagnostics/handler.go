// Package diagnostics adapts existing slog calls to the local development log schema.
package diagnostics

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

var identifier = regexp.MustCompile(`^[A-Za-z0-9_-]{1,96}$`)

type output struct {
	mu     sync.Mutex
	writer io.Writer
}
type Handler struct {
	output                   *output
	run, component, instance string
	attrs                    []slog.Attr
}

// NewHandler never serializes free-form messages, errors, identities or config.
// Source locations identify existing logging call sites without their arguments.
func NewHandler(writer io.Writer, run, component, instance string) (*Handler, error) {
	for _, value := range []string{run, component, instance} {
		if !identifier.MatchString(value) {
			return nil, errors.New("invalid diagnostic identifier")
		}
	}
	return &Handler{output: &output{writer: writer}, run: run, component: component, instance: instance}, nil
}

func (h *Handler) Enabled(_ context.Context, level slog.Level) bool { return level >= slog.LevelInfo }
func (h *Handler) Handle(_ context.Context, record slog.Record) error {
	source := "backend"
	if record.PC != 0 {
		frames := runtime.CallersFrames([]uintptr{record.PC})
		frame, _ := frames.Next()
		source = filepath.Base(frame.File) + ":" + strconv.Itoa(frame.Line)
	}
	attrs := map[string]any{}
	event := "backend_log"
	add := func(attr slog.Attr) {
		value := attr.Value.Resolve()
		if attr.Key == "event_name" {
			switch value.String() {
			case "service_ready", "startup_failed", "shutdown_started", "shutdown_failed", "service_stopped":
				event = value.String()
			}
			return
		}
		switch attr.Key {
		case "duration_ms", "count", "bytes", "attempt", "status_code":
			switch value.Kind() {
			case slog.KindInt64:
				attrs[attr.Key] = value.Int64()
			case slog.KindUint64:
				attrs[attr.Key] = value.Uint64()
			}
		}
	}
	for _, attr := range h.attrs {
		add(attr)
	}
	record.Attrs(func(attr slog.Attr) bool { add(attr); return true })
	level := strings.ToLower(record.Level.String())
	if record.Level == slog.LevelWarn {
		level = "warning"
	}
	envelope := map[string]any{
		"schema_version": 1, "occurred_at": record.Time.UTC().Format(time.RFC3339Nano),
		"run_id": h.run, "instance_id": h.instance, "component": h.component,
		"level": level, "event": event, "message": event, "source": source, "attributes": attrs,
	}
	h.output.mu.Lock()
	defer h.output.mu.Unlock()
	return json.NewEncoder(h.output.writer).Encode(envelope)
}
func (h *Handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	clone := *h
	clone.attrs = append(append([]slog.Attr{}, h.attrs...), attrs...)
	return &clone
}
func (h *Handler) WithGroup(_ string) slog.Handler { clone := *h; return &clone }

// InstallFromEnvironment is a process-entry adapter. Existing defaults are kept
// when no explicit development run is selected. stdout is collected by the host.
func InstallFromEnvironment(component string) error {
	run := os.Getenv("SSH_MOBILE_LOG_RUN_ID")
	if run == "" {
		return nil
	}
	handler, err := NewHandler(os.Stdout, run, component, strconv.Itoa(os.Getpid()))
	if err != nil {
		return err
	}
	slog.SetDefault(slog.New(handler))
	return nil
}
