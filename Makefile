XCODEBUILD := xcodebuild
PROJECT := $(CURDIR)/BoxingCoach.xcodeproj
SCHEME := BoxingCoach
CONFIGURATION := Debug
SIM_DESTINATION := generic/platform=visionOS Simulator
DEVICE_DESTINATION := generic/platform=visionOS
DERIVED_DATA_ROOT := /private/tmp/BoxingCoachDerivedData

.PHONY: all
all: build

.PHONY: build
build:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA_ROOT)/simulator CODE_SIGNING_ALLOWED=NO build

.PHONY: build-device
build-device:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(DEVICE_DESTINATION)' -derivedDataPath $(DERIVED_DATA_ROOT)/device CODE_SIGNING_ALLOWED=NO build
