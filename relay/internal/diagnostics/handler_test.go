package diagnostics

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestHandlerKeepsSafeMetadataAndDropsPrivateValues(t *testing.T) {
	var output bytes.Buffer
	handler, err := NewHandler(&output, "test-run", "relay", "instance")
	if err != nil {
		t.Fatal(err)
	}
	logger := slog.New(handler).With("device_id", "private-device").WithGroup("request")
	logger.ErrorContext(context.Background(), "private-message", "error", "private-error", "duration_ms", 12)
	text := output.String()
	if strings.Contains(text, "private") {
		t.Fatalf("unsafe output: %s", text)
	}
	var record map[string]any
	if err := json.Unmarshal(output.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	if record["run_id"] != "test-run" || record["level"] != "error" {
		t.Fatalf("record: %v", record)
	}
	if record["attributes"].(map[string]any)["duration_ms"] != float64(12) {
		t.Fatalf("attributes: %v", record)
	}
}

type failedOutput struct{}

func (failedOutput) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestProcessInstallationAndHandlerFailures(t *testing.T) {
	previous := slog.Default()
	t.Cleanup(func() { slog.SetDefault(previous) })
	t.Setenv("SSH_MOBILE_LOG_RUN_ID", "")
	if err := InstallFromEnvironment("relay"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SSH_MOBILE_LOG_RUN_ID", "../bad")
	if err := InstallFromEnvironment("relay"); err == nil {
		t.Fatal("invalid identity accepted")
	}
	t.Setenv("SSH_MOBILE_LOG_RUN_ID", "fixture-run")
	if err := InstallFromEnvironment("relay"); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	handler, _ := NewHandler(&output, "run", "admin", "instance")
	record := slog.NewRecord(time.Now(), slog.LevelWarn, "private-message", 0)
	record.AddAttrs(slog.String("event_name", "service_ready"), slog.Uint64("count", 2),
		slog.String("count", "private-value"), slog.String("unknown", "private-value"))
	if err := handler.Handle(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), "private") || !strings.Contains(output.String(), "warning") {
		t.Fatal(output.String())
	}
	failed, _ := NewHandler(failedOutput{}, "run", "admin", "instance")
	if err := failed.Handle(context.Background(), record); err == nil {
		t.Fatal("writer failure hidden")
	}
}

func TestHandlerRejectsInvalidIdentityAndHonorsLevel(t *testing.T) {
	if _, err := NewHandler(&bytes.Buffer{}, "../bad", "relay", "instance"); err == nil {
		t.Fatal("accepted traversal")
	}
	handler, err := NewHandler(&bytes.Buffer{}, "run", "admin", "instance")
	if err != nil {
		t.Fatal(err)
	}
	if handler.Enabled(context.Background(), slog.LevelDebug) {
		t.Fatal("debug enabled")
	}
}
