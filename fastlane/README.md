fastlane documentation
================
# Installation
```
sudo gem install fastlane
```
# Available Actions
## iOS
### ios prepare_cache
```
fastlane ios prepare_cache
```
Install dependencies from cache
### ios test
```
fastlane ios test
```
Runs all the tests
### ios ci
```
fastlane ios ci
```
Runs all the tests in a CI environment
### ios release
```
fastlane ios release
```
Performs the release of the library to Cocoapods & Github Releases

You need to specify the type of release with the `bump` parameter with the values [major|minor|patch]

----

This README.md is auto-generated and will be re-generated every time [fastlane](https://fastlane.tools) is run.
More information about fastlane can be found on [https://fastlane.tools](https://fastlane.tools).
The documentation of fastlane can be found on [GitHub](https://github.com/fastlane/fastlane/tree/master/fastlane).
