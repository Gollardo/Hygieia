# App

Composition root, lifecycle и platform adapters нативного SwiftUI-приложения. UI-код не содержит scanner/filesystem implementation: scanner, visualization и file-operation contracts приходят из отдельных SwiftPM products, а AppKit используется только в platform boundary.
