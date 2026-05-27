.PHONY: build app zip dmg release-artifacts verify-release install clean

build:
	cd macos && swift build -c release

app:
	bash macos/scripts/build.sh

zip:
	bash macos/scripts/build.sh --zip
	bash macos/scripts/verify-release.sh macos/AgentUsageBar.zip

dmg:
	bash macos/scripts/build.sh --dmg
	bash macos/scripts/verify-release.sh macos/AgentUsageBar.dmg

release-artifacts:
	bash macos/scripts/build.sh --zip --dmg
	bash macos/scripts/verify-release.sh macos/AgentUsageBar.zip
	bash macos/scripts/verify-release.sh macos/AgentUsageBar.dmg

verify-release:
	bash macos/scripts/verify-release.sh macos/AgentUsageBar.zip
	if [ -f macos/AgentUsageBar.dmg ]; then bash macos/scripts/verify-release.sh macos/AgentUsageBar.dmg; fi

install: app
	rm -rf "/Applications/Agent Usage Bar.app"
	cp -R "macos/Agent Usage Bar.app" /Applications/

clean:
	cd macos && swift package clean
	rm -rf "macos/Agent Usage Bar.app" macos/AgentUsageBar.zip macos/AgentUsageBar.dmg
