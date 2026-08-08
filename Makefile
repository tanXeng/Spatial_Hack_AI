XCODEBUILD := xcodebuild
PROJECT := $(CURDIR)/ShadowBox.xcodeproj
SCHEME := ShadowBox
CONFIGURATION := Debug
SIM_DESTINATION := generic/platform=visionOS Simulator
DEVICE_DESTINATION := generic/platform=visionOS
DERIVED_DATA_ROOT := /private/tmp/ShadowBoxDerivedData
OFFLINE_FLAGS := SHADOWBOX_OFFLINE_MODE=1

.PHONY: all
all: build

.PHONY: build
build:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA_ROOT)/simulator CODE_SIGNING_ALLOWED=NO build

.PHONY: build-offline
build-offline:
	$(OFFLINE_FLAGS) $(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA_ROOT)/simulator CODE_SIGNING_ALLOWED=NO build

.PHONY: build-device
build-device:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(DEVICE_DESTINATION)' -derivedDataPath $(DERIVED_DATA_ROOT)/device CODE_SIGNING_ALLOWED=NO build
