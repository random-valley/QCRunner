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

@main
struct QCRunnerApp: App {
    let logger = LoggerModule().component(name: "QCRunner")
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
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
    
    fileprivate func makeAnalysisFrame(fromBaseframe baseframe: CIImage) async throws -> AnalysisFrame {
        let tagDesign = makeTagDesignDescriptionForNC01()
        let patchCropper = NC01PatchCropOperation(barcodeAnchorX: 0.1333, barcodeAnchorY: 0.75, xDirection: .plus, yDirection: .plus, xRatio: 0.5066666666, yRatio: 0.25, widthInset: 0.9, heightInset: 0.4)
        let refCropper = NC01CompositeReferenceRegionCropper()
        let barcodeCropper = DataMatrixBarcodeCroppingOperation(tag: tagDesign, logger: self.logger, dataMatrixOrientation: .upright, payloadSearchString: "")
        
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
    
    fileprivate func makeQCPipeline() -> FrameAnalysisService {
        let pipelineBuilder = DownselectionPipelineBuilder(graphics: GraphicsContextModule().component(), logger: self.logger)
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
        let frame = try await makeAnalysisFrame(fromBaseframe: image)
        let pipeline = makeQCPipeline()
        do {
            try _ = pipeline.run(on: [frame])
        } catch {}
        return pipeline.generateReport()
    }
    
    func calculateQCScores(forDataIn inputPath: URL, andOutputTo outputPath: URL) async throws {
        let run = self.runQC(onFilePath:)
        
        let imageURLs = try FileManager.default.subpathsOfDirectory(atPath: inputPath.path(percentEncoded: false)).filter{
            path in
            path.hasSuffix(".json") == false && path.contains("baseframe") && path.contains("calibration") == false && path.contains("material") == false
        }.map{ path in NSURL(fileURLWithPath: inputPath.appending(path: path.description).path(percentEncoded: false)) as URL }
        
        var qcResults = [ [String: String] ]()
        for url in imageURLs {
            do {
                let result = try await run(url)
                var reformatedResults = [String: String]()
                for key in result.keys{
                    reformatedResults[key.rawValue] = result[key]![0].description
                }
                reformatedResults["filepath"] = url.path(percentEncoded: false)
                qcResults.append(reformatedResults)
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
    
    
    init() {
        let csvOutputPath = URL(string: "/Users/blake/Desktop/example.txt")!
        let dataInputPath = URL(string: "/Users/blake/Downloads/iP14_NC01&02_C29_sanity_check/SA1E-real-on-product")!
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
    
    fileprivate func makeTagDesignDescriptionForNC01() -> TagDesignDescription {
        return .init(identityAreaHeightInMM: 7, trackingMarkerWidthInMM: 8.5, referenceAreaLeftCornerInBaseFrame: .init(x: 0.13, y: 0.75), baseframeWidthInMM: 15, trackerLeftCornerInBaseFrame: .init(x: 0.299, y: 0.55), identityAreaWidthInMM: 7.59, trackingMarkerHeightInMM: 6.5, createdAt: "", referenceAreaWidthInMM: 2.5, carrierHeightInMM: 28, carrierWidthInMM: 13, baseframeHeightInMM: 28, identityAreaMinimumResolutionForID: .init(height: 150, width: 150), formatId: "NC01", updatedAt: "", referenceAreaHeightInMM: 10, id: "NC01", identityAreaInsetCropAmount: .init(height: 0.4, width: 0.9), identityAreaPositionRelativeToTrackingMarkerBottomLeftCorner: .init(x: 0, y: 0), printDriftInMM: .init(x: 0, y: 0))
    }
        

//    func example () {
//        
//        // create a String with the table
//        
//        let s = String("")
//        
//        // turn String into Data
//        let data = s.data(using: .utf8)
//        
//        // Write data to URL on disk
//        let savePath = URL(string: "/Users/blake/Desktop/example.txt")!
//        do {
//            try s.write(to: savePath, atomically: true, encoding: .utf8)
//        } catch {print(error)}
//    }
}
