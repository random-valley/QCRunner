//
//  QCRunnerApp.swift
//  QCRunner
//
//  Created by Blake on 02/06/2025.
//

import SwiftUI
import QIDOLib
import QIDOValidation
import QIDOSDK
import QIDOModels
import QIDOUtils
import QIDOScanner
import QIDOTags
import QIDOFrameStream

@main
struct QCRunnerApp: App {
    var contentView = ContentView()
    var runner = QCRunner()
    
    var body: some Scene {
        WindowGroup {
            contentView
            Button("Start", action: runner.run)
        }
    }
}

class QCRunner {
    let logger = LoggerModule().component(name: "QCRunner")
    let profilingLogger = LoggerModule().component(name: "Profiling")

    
    var progressUpdater: ((Int)->Void)?
    var progressTotalUpdater: ((Int)->Void)?
    var viewPathUpdater: ((String)->Void)?
        
    var analysisFrameMaker: ((CIImage, Logger) async throws -> AnalysisFrame)
    var framePathFilter: ((String)->Bool)
    
    lazy var qcPipeline: FrameAnalysisService = {
        makeQCPipeline(withLogger: self.logger)
    }()
    
 
    
    fileprivate func sdkStart() async {
        typealias ConfigHandler = ((inout QIDOSDKStartConfigurations) -> Void)
        let apiDomain = URL(string: "https://verify-zn7u.d.q-id.me")
        let apiToken = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJuYW1lIjoiaW9zIiwiaXNzIjoiZC5xLWlkLm1lIiwianRpIjoiMTQzNTUxYTEtNzQ2OC00Y2Y0LWJlZTgtMzRhZDE5OTJmM2I3IiwiaWF0IjoxNjk3NTYzODU2fQ.MgtTfIp6sfgtEm0IxZtZjPjuwQuUsjfzU5eXPsY8F74EQvHjnpGU0F1bMcYeGQjylYne-B1DpxWJVPfA_sGhmw"
        
        let configureSDK: ConfigHandler = { configs in
            configs.apiToken = apiToken
            configs.apiDomain = apiDomain!
            configs.enableSupportedDeviceCheck = false
            configs.storageOption = .remote
        }
        
        return await withCheckedContinuation({ continuation in
            QIDOSDK.start(configureSDK, { (_, _) in
                continuation.resume()
            })
        })
    }
    
    fileprivate func makeQCPipeline(withLogger logger: Logger) -> FrameAnalysisService {
        let pipelineBuilder = DownselectionPipelineBuilder(graphics: GraphicsContextModule().component(), logger: logger)
        pipelineBuilder.checkAllFramesAreUnique()
        pipelineBuilder.checkBlueDominatedPixels(populationRatioIsBelowThreshold: -.infinity)
        pipelineBuilder.checkFrameBarcodeContrast(codecontrastLowerBound: -.infinity, codecontrastUpperBound: .infinity)
        pipelineBuilder.checkFrameBarcodeEdges(edgesLowerBound: -.infinity, edgesUpperBound: .infinity)
        pipelineBuilder.checkFrameBrightness(isAboveThreshold: -.infinity)
        pipelineBuilder.checkFrameContrast(lowerBound: -.infinity, upperBound: .infinity, channel: .Green)
        pipelineBuilder.checkFrameMinContrast(minContrastLowerBound: -.infinity, minContrastUpperBound: .infinity)
        pipelineBuilder.checkFrameRegionalContrast(regionalLowerBound: -.infinity, regionalUpperBound: .infinity)
        pipelineBuilder.checkFrameSharpness(sharpnessLowerBound: -.infinity, sharpnessUpperBound: .infinity, params: [:])
        pipelineBuilder.checkLaplacianSharpness(laplacianLowerBound: -.infinity, laplacianUpperBound: .infinity)
        pipelineBuilder.checkSpecularReflection(speckleLowerBound: -.infinity, speckleUpperBound: .infinity)
        return pipelineBuilder.build()
    }
    
    fileprivate func runQC(onFilePath imageURL: URL) async throws -> [FrameAnalysisOperationName : [Double]] {
        let image = CIImage(contentsOf: imageURL)!
        let frame = try await analysisFrameMaker(image, self.logger)
        do {
            try _ = qcPipeline.run(on: [frame])
        } catch {}
        return qcPipeline.generateReport()
    }
    
//    mutating func updateTotal(to newTotal: Int){ contentView.updateTotal(to: newTotal)}
//    mutating func updatePath(to newPath: String){ contentView.updatePath(to: newPath)}
//    mutating func updateCurrentPlace(to newValue: Int){ contentView.updateCurrentPlace(to: newValue)}
    
    func calculateQCScores(forDataIn inputPath: URL, andOutputTo outputPath: URL) async throws {
        let run = self.runQC(onFilePath:)
        
        let imageURLs = try FileManager.default.subpathsOfDirectory(atPath: inputPath.path(percentEncoded: false))
            .map{path in inputPath.appending(path: path.description).path(percentEncoded: false)}
            .filter{ path in framePathFilter(path) }
            .map{ path in NSURL(fileURLWithPath: path) as URL}
        
        var qcResults = [ [String: String] ]()
        
        let startTime = Date.timeIntervalSinceReferenceDate
        var startTimeFrame = Date.timeIntervalSinceReferenceDate
        var endTimeFrame = Date.timeIntervalSinceReferenceDate
        var averageTimePerFrame = 1.0
        var estTimeRemaining = 1.0
        
        for (i, url) in imageURLs.enumerated() {
            
            do {
                startTimeFrame = Date.timeIntervalSinceReferenceDate
                let result = try await run(url)
                var reformatedResults = [String: String]()
                for key in result.keys{
                    reformatedResults[key.rawValue] = result[key]![0].description
                }
                reformatedResults["filepath"] = url.path(percentEncoded: false)
                qcResults.append(reformatedResults)
                
                endTimeFrame = Date.timeIntervalSinceReferenceDate
                averageTimePerFrame = (Date.timeIntervalSinceReferenceDate - startTime) / Double(i+1)
                estTimeRemaining = averageTimePerFrame * Double(imageURLs.count - i - 1)
                profilingLogger.info("[Profiling] Completed run \(i)/\(imageURLs.count) in \(endTimeFrame - startTimeFrame) s --- est time remaining: \( Int(estTimeRemaining / 60) ) mins")
            } catch {
                print("\(error) whilst running QC for \(url)")
            }
        }
        
        
        let joinByCommas = {x, y in x + y + ","}
        let headers = qcResults[0].keys.sorted()
        let qcValuesAsString = qcResults.map{
            qcResult in
            var values = [String]()
            for col in headers{
                values.append(qcResult[col]!)
            }
            return values.reduce("", joinByCommas)
        }
        let rows = [headers.reduce("", joinByCommas)] + qcValuesAsString
        
        do {
            try rows.reduce("", { x, y in x + y + "\n"} ).write(to: outputPath, atomically: true, encoding: .utf8)
        } catch {
            print("Error during csv writing")
        }
    }
    
    
    fileprivate func run() {
        let csvOutputPath = URL(string: "/Users/blake/Desktop/example.csv")!
        let dataInputPath = URL(string: "/Volumes/NAS2Fast/QB datasets/Store/Sorted data/Apple/iPhone 16")!
        let funcToRun = calculateQCScores(forDataIn: andOutputTo:)
        let startSDK = sdkStart
        
        Task {
            do {
                await startSDK()
                try await funcToRun(dataInputPath, csvOutputPath)
            } catch {
                print("Encountered erorr \(error)")
            }
        }
    }
    
    init() {
        self.analysisFrameMaker = makeQ0aAnalysisFrame(fromBaseframe: withLogger:)
        self.framePathFilter = pathFilter(path:)
    }
}


// Path filters
func pathFilter(path: String) -> Bool{
    if path.hasSuffix(".json") { return false }
    if path.contains("baseframe") == false { return false }
    if path.contains("calibration") == true { return false }
    if path.contains("material") == true { return false }
    if path.contains("Q0a") == false { return false}
    return true
}


// Tag design creation functions

fileprivate func makeTagDesignDescriptionForNC01() -> TagDesignDescription {
    return .init(identityAreaHeightInMM: 7, trackingMarkerWidthInMM: 8.5, referenceAreaLeftCornerInBaseFrame: .init(x: 0.13, y: 0.75), baseframeWidthInMM: 15, trackerLeftCornerInBaseFrame: .init(x: 0.299, y: 0.55), identityAreaWidthInMM: 7.59, trackingMarkerHeightInMM: 6.5, createdAt: "", referenceAreaWidthInMM: 2.5, carrierHeightInMM: 28, carrierWidthInMM: 13, baseframeHeightInMM: 28, identityAreaMinimumResolutionForID: .init(height: 150, width: 150), formatId: "NC01", updatedAt: "", referenceAreaHeightInMM: 10, id: "NC01", identityAreaInsetCropAmount: .init(height: 0.4, width: 0.9), identityAreaPositionRelativeToTrackingMarkerBottomLeftCorner: .init(x: 0, y: 0), printDriftInMM: .init(x: 0, y: 0))
}

fileprivate func makeTagDesignDescriptionForQ0a() -> TagDesignDescription {
    return .init(identityAreaHeightInMM: 12, trackingMarkerWidthInMM: 7, referenceAreaLeftCornerInBaseFrame: .init(x: 0, y: 0), baseframeWidthInMM: 16, trackerLeftCornerInBaseFrame: .init(x: 0.28499999999, y: 0.714999999999), identityAreaWidthInMM: 12, trackingMarkerHeightInMM: 7, createdAt: "", referenceAreaWidthInMM: 16, carrierHeightInMM: 16, carrierWidthInMM: 16, baseframeHeightInMM: 16, identityAreaMinimumResolutionForID: .init(height: 260, width: 260), formatId: "Q0a", updatedAt: "", referenceAreaHeightInMM: 16, id: "Q0a", identityAreaInsetCropAmount: .init(height: 0, width: 0), identityAreaPositionRelativeToTrackingMarkerBottomLeftCorner: .init(x: 0, y: 0), printDriftInMM: .init(x: 0.5, y: 0.5))
}


// Analysis Frame creation functions

public func qrDetector() -> CIDetector? {
    return CIDetector(ofType: CIDetectorTypeQRCode, context: GraphicsContextModule().component().context, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
}

fileprivate func makeQ0aAnalysisFrame(fromBaseframe baseframe: CIImage, withLogger logger: Logger) async throws -> AnalysisFrame {
    let tagDesign = makeTagDesignDescriptionForQ0a()
    let patchCropper = InsetBarcodeLayoutCompositePatchRegionCropper(tagDesign)
    let refCropper = InsetBarcodeLayoutCompositeReferenceRegionCropper(tagDesign)
    let barcodeCropper = QRCodeBarcodeCroppingOperation(detector: qrDetector(), logger: logger)
    
    // crop ref from baseframe
    let ref = try refCropper.execute(onBaseframe: baseframe)
    // crop patch from baseframe
    let patch = try patchCropper.execute(onBaseframeRegion: baseframe)
    // crop barcode from baseframe
    let barcode = try await barcodeCropper.execute(on: baseframe)
    // generate dummy QRCode data
    let qrCode = QRCode(payload: "some_payload")
    let cameraSettings = CameraSettings(whiteBalanceMode: .automatic, exposureMode: .automatic, torchMode: .off)
    
    return .init(uuid: UUID(), baseframe: baseframe, referenceRegion: ref, quantumPatchRegion: patch, barcodeRegion: barcode, settingsAtCapture: cameraSettings, qrCode: qrCode)
}

fileprivate func makeNC01AnalysisFrame(fromBaseframe baseframe: CIImage, withLogger logger: Logger) async throws -> AnalysisFrame {
    let tagDesign = makeTagDesignDescriptionForNC01()
    let patchCropper = NC01PatchCropOperation(barcodeAnchorX: 0.1333, barcodeAnchorY: 0.75, xDirection: .plus, yDirection: .plus, xRatio: 0.5066666666, yRatio: 0.25, widthInset: 0.9, heightInset: 0.4)
    let refCropper = NC01CompositeReferenceRegionCropper()
//    let barcodeCropper = DataMatrixBarcodeCroppingOperation(tag: tagDesign, logger: logger, dataMatrixOrientation: .upright, payloadSearchString: "")
    
    // crop ref from baseframe
    let ref = try refCropper.execute(onBaseframe: baseframe)
    // crop patch from baseframe
    let patch = try patchCropper.execute(onBaseframeRegion: baseframe)
    // crop barcode from baseframe
//        let barcode = try await barcodeCropper.execute(on: baseframe)
    // generate dummy QRCode data
    let qrCode = QRCode(payload: "some_payload")
    let cameraSettings = CameraSettings(whiteBalanceMode: .automatic, exposureMode: .automatic, torchMode: .off)
    
    return .init(uuid: UUID(), baseframe: baseframe, referenceRegion: ref, quantumPatchRegion: patch, barcodeRegion: baseframe, settingsAtCapture: cameraSettings, qrCode: qrCode)
}
