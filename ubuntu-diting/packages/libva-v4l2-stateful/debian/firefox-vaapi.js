// Hardware video decoding on the Xiaomi 12T Pro (iris decoder through the
// default VA-API driver, qcom-va-driver under the msm name). Firefox does
// not enable VA-API on this GPU/driver combination by itself.
pref("media.hardware-video-decoding.force-enabled", true);
