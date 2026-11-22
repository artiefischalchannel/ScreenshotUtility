.PHONY: build app run clean

build:
	swift build

app:
	bash Scripts/build-app.sh

run:
	swift run ScreenshotUtility

clean:
	rm -rf .build dist
