package main

import (
	"errors"
	"flag"
	"fmt"
	"os"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"
)

const (
	messageName       = "RealtimeSignal"
	sourceFieldName   = "source_device_id"
	sourceFieldNumber = int32(7)
)

func main() {
	currentPath := flag.String("current", "", "current relay v2 FileDescriptorSet")
	frozenPath := flag.String("frozen", "", "frozen relay v2 FileDescriptorSet")
	flag.Parse()
	if *currentPath == "" || *frozenPath == "" {
		fmt.Fprintln(os.Stderr, "--current and --frozen are required")
		os.Exit(2)
	}
	if err := check(*currentPath, *frozenPath); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("relay v2 descriptor: only RealtimeSignal.source_device_id tag 7 differs from frozen")
}

func check(currentPath, frozenPath string) error {
	current, err := readDescriptorSet(currentPath)
	if err != nil {
		return fmt.Errorf("read current descriptor: %w", err)
	}
	frozen, err := readDescriptorSet(frozenPath)
	if err != nil {
		return fmt.Errorf("read frozen descriptor: %w", err)
	}

	currentMessage, err := findRealtimeSignal(current)
	if err != nil {
		return fmt.Errorf("current descriptor: %w", err)
	}
	fieldIndex, err := validateSourceField(currentMessage)
	if err != nil {
		return fmt.Errorf("current descriptor: %w", err)
	}

	withoutSource := proto.Clone(current).(*descriptorpb.FileDescriptorSet)
	message, err := findRealtimeSignal(withoutSource)
	if err != nil {
		return fmt.Errorf("current descriptor clone: %w", err)
	}
	message.Field = append(message.Field[:fieldIndex], message.Field[fieldIndex+1:]...)

	marshal := proto.MarshalOptions{Deterministic: true}
	actual, err := marshal.Marshal(withoutSource)
	if err != nil {
		return fmt.Errorf("marshal current descriptor without additive field: %w", err)
	}
	expected, err := marshal.Marshal(frozen)
	if err != nil {
		return fmt.Errorf("marshal frozen descriptor: %w", err)
	}
	if !proto.Equal(withoutSource, frozen) || string(actual) != string(expected) {
		return errors.New("current relay v2 descriptor has changes beyond RealtimeSignal.source_device_id tag 7")
	}
	return nil
}

func readDescriptorSet(path string) (*descriptorpb.FileDescriptorSet, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	set := new(descriptorpb.FileDescriptorSet)
	if err := proto.Unmarshal(data, set); err != nil {
		return nil, err
	}
	return set, nil
}

func findRealtimeSignal(set *descriptorpb.FileDescriptorSet) (*descriptorpb.DescriptorProto, error) {
	var found *descriptorpb.DescriptorProto
	for _, file := range set.File {
		if file.GetPackage() != "relay.v2" {
			continue
		}
		for _, message := range file.MessageType {
			if message.GetName() != messageName {
				continue
			}
			if found != nil {
				return nil, errors.New("duplicate relay.v2.RealtimeSignal descriptor")
			}
			found = message
		}
	}
	if found == nil {
		return nil, errors.New("relay.v2.RealtimeSignal descriptor is missing")
	}
	return found, nil
}

func validateSourceField(message *descriptorpb.DescriptorProto) (int, error) {
	fieldIndex := -1
	for index, field := range message.Field {
		if field.GetNumber() == sourceFieldNumber || field.GetName() == sourceFieldName {
			if fieldIndex != -1 {
				return 0, errors.New("source_device_id tag/name is duplicated")
			}
			fieldIndex = index
			if field.GetName() != sourceFieldName ||
				field.GetNumber() != sourceFieldNumber ||
				field.GetType() != descriptorpb.FieldDescriptorProto_TYPE_STRING ||
				field.GetLabel() != descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL ||
				field.GetProto3Optional() {
				return 0, errors.New("source_device_id must be singular string field tag 7")
			}
		}
	}
	if fieldIndex == -1 {
		return 0, errors.New("source_device_id tag 7 is missing")
	}
	return fieldIndex, nil
}
