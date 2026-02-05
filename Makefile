CONFIG = Debug

DERIVED_DATA_PATH = ~/.derivedData/$(CONFIG)

PLATFORM = macOS
DESTINATION = platform="$(PLATFORM)"
SCHEME = UndoForMacOS

XCODEBUILD_ARGUMENT = build

XCODEBUILD_FLAGS = \
	-configuration $(CONFIG) \
	-derivedDataPath $(DERIVED_DATA_PATH) \
	-destination $(DESTINATION) \
	-project Examples/Examples.xcodeproj \
	-scheme "$(SCHEME)" \
	-skipMacroValidation

XCODEBUILD_COMMAND = xcodebuild $(XCODEBUILD_ARGUMENT) $(XCODEBUILD_FLAGS)

ifneq ($(strip $(shell which xcbeautify)),)
	XCODEBUILD = set -o pipefail && $(XCODEBUILD_COMMAND) | xcbeautify
else
	XCODEBUILD = $(XCODEBUILD_COMMAND)
endif

xcodebuild:
	$(XCODEBUILD)

xcodebuild-raw:
	$(XCODEBUILD_COMMAND)

format:
	find . \
		-path '*/Documentation.docc' -prune -o \
		-name '*.swift' \
		-not -path '*/.*' -print0 \
		| xargs -0 xcrun swift-format --ignore-unparsable-files --in-place

.PHONY: format xcodebuild xcodebuild-raw
