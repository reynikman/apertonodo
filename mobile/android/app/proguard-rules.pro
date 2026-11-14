# R8 rules for the release build.
#
# build.gradle.kts refers to this file, but it did not exist, and release was not
# built in any flavor: "Supplied proguard configuration does not
# exist" (audit of 18 September). The owner had a debug build installed.
#
# Flutter adds its own rules itself, and the audio plugins (just_audio,
# audio_service) carry theirs inside the AAR. Here only what was missing.
