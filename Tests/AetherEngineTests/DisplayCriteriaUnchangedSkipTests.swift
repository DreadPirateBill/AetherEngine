import Testing
import CoreMedia
import CoreVideo
@testable import AetherEngine

// #133 Issue B: on a same-format live zap (e.g. SDR 50 Hz -> SDR 50 Hz), the engine re-applied identical
// AVDisplayCriteria unconditionally. On a Dolby-Vision panel that redundant write triggers an unobservable
// mode switch, and the unconditional post-load waitForSwitch() then burns the full ~3000 ms cap on every
// zap. The controller retains no last-applied criteria, so it cannot tell the mode is already active.
//
// The fix retains the last-applied criteria and skips the panel write (and the settle wait) only when we
// previously applied exactly these criteria and have not reset since. This suite covers that pure DECISION.
@Suite("DisplayCriteria unchanged-apply skip")
struct DisplayCriteriaUnchangedSkipTests {

    private let hvc1: CMVideoCodecType = kCMVideoCodecType_HEVC
    private let dvh1: CMVideoCodecType = 0x64766831

    private func sdr50() -> DisplayCriteriaController.AppliedCriteria {
        .init(isHDR: false, effectiveRate: 50, codecType: hvc1, hasExtensions: false)
    }

    @Test("First apply of a session (nothing applied yet) is never skipped")
    func firstApplyNotSkipped() {
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: false, last: nil, target: sdr50()) == .applied)
    }

    @Test("Re-applying identical SDR criteria after a prior apply is skipped as unchanged")
    func identicalSdrSkipped() {
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: sdr50()) == .unchanged)
    }

    @Test("A rate change is applied, not skipped")
    func rateChangeApplied() {
        let target = DisplayCriteriaController.AppliedCriteria(
            isHDR: false, effectiveRate: 60, codecType: hvc1, hasExtensions: false)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: target) == .applied)
    }

    @Test("A format change into HDR yields willSwitch (caller must settle the panel)")
    func hdrChangeWillSwitch() {
        let target = DisplayCriteriaController.AppliedCriteria(
            isHDR: true, effectiveRate: 24, codecType: hvc1, hasExtensions: true)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: target) == .willSwitch)
    }

    @Test("A codec change (hvc1 -> dvh1, Dolby Vision) at the same rate is applied, not skipped")
    func codecChangeApplied() {
        let target = DisplayCriteriaController.AppliedCriteria(
            isHDR: true, effectiveRate: 50, codecType: dvh1, hasExtensions: true)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: target) == .willSwitch)
    }

    @Test("Identical HDR criteria re-applied is still skipped (unobservable-DV zap between two HDR channels)")
    func identicalHdrSkipped() {
        let hdr = DisplayCriteriaController.AppliedCriteria(
            isHDR: true, effectiveRate: 50, codecType: dvh1, hasExtensions: true)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: hdr, target: hdr) == .unchanged)
    }

    @Test("After a reset (didApply cleared) the same criteria are applied fresh, not skipped")
    func afterResetNotSkipped() {
        // reset() nils lastApplied and clears didApply; the next load must re-establish the panel mode.
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: false, last: nil, target: sdr50()) == .applied)
    }

    @Test("Identical criteria are written again when the display manager no longer holds any (AE#678)")
    func hostClearedCriteriaAreRewritten() {
        // A host that nils preferredDisplayCriteria itself (leaving full screen) left lastApplied stale,
        // and the next same-format load kept the panel in its UI mode.
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: sdr50(), managerHoldsCriteria: false) == .applied)
        let hdr = DisplayCriteriaController.AppliedCriteria(
            isHDR: true, effectiveRate: 50, codecType: dvh1, hasExtensions: true)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: hdr, target: hdr, managerHoldsCriteria: false) == .willSwitch)
    }

    // MARK: - Sprocket fork: the manager's own contents decide the skip

    private static let hdrTarget = DisplayCriteriaController.AppliedCriteria(
        isHDR: true, effectiveRate: 23.976, codecType: kCMVideoCodecType_HEVC, hasExtensions: true)

    @Test("The engine's own HDR write read back is the target: skip")
    func ownWriteReadsAsTarget() {
        let reading = DisplayCriteriaController.CriteriaReading(
            refreshRate: 23.976, codecType: kCMVideoCodecType_HEVC, hasExtensions: true, transferIsHDR: true)
        #expect(DisplayCriteriaController.managerHoldsTarget(reading, target: Self.hdrTarget))
    }

    @Test("A host's SDR rate request is not the target, whatever its rate: write again")
    func hostSDRRequestIsForeign() {
        let sameRate = DisplayCriteriaController.CriteriaReading(
            refreshRate: 23.976, codecType: kCVPixelFormatType_64RGBAHalf, hasExtensions: true, transferIsHDR: false)
        let otherRate = DisplayCriteriaController.CriteriaReading(
            refreshRate: 24, codecType: kCVPixelFormatType_64RGBAHalf, hasExtensions: true, transferIsHDR: false)
        #expect(DisplayCriteriaController.managerHoldsTarget(sameRate, target: Self.hdrTarget) == false)
        #expect(DisplayCriteriaController.managerHoldsTarget(otherRate, target: Self.hdrTarget) == false)
    }

    @Test("An empty manager is a cleared one: write again")
    func emptyManagerIsCleared() {
        #expect(DisplayCriteriaController.managerHoldsTarget(nil, target: Self.hdrTarget) == false)
    }

    @Test("Criteria written without colour extensions cannot say their range, and still skip their own")
    func extensionlessWriteSkipsItself() {
        let target = DisplayCriteriaController.AppliedCriteria(
            isHDR: true, effectiveRate: 24, codecType: kCMVideoCodecType_HEVC, hasExtensions: false)
        let reading = DisplayCriteriaController.CriteriaReading(
            refreshRate: 24, codecType: kCMVideoCodecType_HEVC, hasExtensions: false, transferIsHDR: nil)
        #expect(DisplayCriteriaController.managerHoldsTarget(reading, target: target))
    }
}
