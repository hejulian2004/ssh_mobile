package main

import (
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"
)

func TestCheckAcceptsOnlyTheAdditiveSourceField(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	frozenPath := filepath.Join(dir, "frozen.desc")
	currentPath := filepath.Join(dir, "current.desc")
	frozen := descriptorSetWithRealtimeSignal(nil)
	current := descriptorSetWithRealtimeSignal(&descriptorpb.FieldDescriptorProto{
		Name:   proto.String(sourceFieldName),
		Number: proto.Int32(sourceFieldNumber),
		Type:   descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
		Label:  descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
	})
	writeDescriptor(t, frozenPath, frozen)
	writeDescriptor(t, currentPath, current)

	if err := check(currentPath, frozenPath); err != nil {
		t.Fatalf("additive source field should be accepted: %v", err)
	}
}

func TestCheckRejectsASecondDescriptorChange(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	frozenPath := filepath.Join(dir, "frozen.desc")
	currentPath := filepath.Join(dir, "current.desc")
	frozen := descriptorSetWithRealtimeSignal(nil)
	current := descriptorSetWithRealtimeSignal(&descriptorpb.FieldDescriptorProto{
		Name:   proto.String(sourceFieldName),
		Number: proto.Int32(sourceFieldNumber),
		Type:   descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
		Label:  descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
	})
	current.File[0].MessageType[0].Field = append(
		current.File[0].MessageType[0].Field,
		&descriptorpb.FieldDescriptorProto{
			Name:   proto.String("unexpected"),
			Number: proto.Int32(8),
			Type:   descriptorpb.FieldDescriptorProto_TYPE_BYTES.Enum(),
			Label:  descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
		},
	)
	writeDescriptor(t, frozenPath, frozen)
	writeDescriptor(t, currentPath, current)

	if err := check(currentPath, frozenPath); err == nil {
		t.Fatal("descriptor drift beyond source_device_id must fail")
	}
}

func descriptorSetWithRealtimeSignal(source *descriptorpb.FieldDescriptorProto) *descriptorpb.FileDescriptorSet {
	message := &descriptorpb.DescriptorProto{Name: proto.String(messageName)}
	if source != nil {
		message.Field = append(message.Field, source)
	}
	return &descriptorpb.FileDescriptorSet{File: []*descriptorpb.FileDescriptorProto{{
		Name:        proto.String("relay/v2/relay_v2.proto"),
		Package:     proto.String("relay.v2"),
		MessageType: []*descriptorpb.DescriptorProto{message},
	}}}
}

func writeDescriptor(t *testing.T, path string, set *descriptorpb.FileDescriptorSet) {
	t.Helper()
	data, err := (proto.MarshalOptions{Deterministic: true}).Marshal(set)
	if err != nil {
		t.Fatalf("marshal descriptor: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write descriptor: %v", err)
	}
}
