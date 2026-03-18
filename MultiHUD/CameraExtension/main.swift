//
//  main.swift
//  CameraExtension
//

import Foundation
import CoreMediaIO

let providerSource = CameraExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

// Wire weather file updates into the overlay.
WeatherService.shared.onUpdate = { text in
    providerSource.deviceSource.overlayText = text
}

CFRunLoopRun()
