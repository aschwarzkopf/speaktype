// Default committed content. Overwritten by `make stamp-build-info`
// only during release builds (see Makefile). Debug / dev-loop targets
// leave this alone so the tracked file does not churn on every rebuild.
let buildTimestamp = "development"
