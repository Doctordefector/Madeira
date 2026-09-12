# ci/prebuilt

Drop a base `libwineserver.a` here to unblock `ci/30-native-libs.sh`.

`build/wineserver/build.sh` patches an existing archive rather than building
one from scratch, and upstream gitignores the base. See [`../README.md`](../README.md).

Nothing here is gitignored — committing the archive is how CI gets it without
a `WINESERVER_BASE_URL`. It is a few MB; if you would rather keep it out of
git history, host it and set that variable instead.
