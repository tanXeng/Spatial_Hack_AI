XCODEBUILD := xcodebuild
PROJECT := $(CURDIR)/BoxingCoach.xcodeproj
SCHEME := BoxingCoach
CONFIGURATION := Debug
SIM_DESTINATION := generic/platform=visionOS Simulator
DEVICE_DESTINATION := generic/platform=visionOS
TEST_DESTINATION := platform=visionOS Simulator,name=Apple Vision Pro,OS=27.0
DERIVED_DATA_ROOT := /private/tmp/BoxingCoachDerivedData

.PHONY: all
all: build

.PHONY: build
build:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA_ROOT)/simulator CODE_SIGNING_ALLOWED=NO build

.PHONY: build-device
build-device:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(DEVICE_DESTINATION)' -derivedDataPath $(DERIVED_DATA_ROOT)/device CODE_SIGNING_ALLOWED=NO build

.PHONY: test
test:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(TEST_DESTINATION)' -derivedDataPath $(DERIVED_DATA_ROOT)/tests CODE_SIGNING_ALLOWED=NO test
