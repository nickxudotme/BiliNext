import CoreMedia
import VideoToolbox

public enum MediaCapabilities {
    /// Query the decoder, rather than infer support from a machine name or chip generation.
    public static var hardwareAV1: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }
}
