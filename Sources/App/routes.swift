import Vapor

private let cache = Cache<String, ByteBuffer>()

func routes(_ app: Application) throws {
    app.get { (req) in try index(req) }
    app.get("index.html") { (req) in try index(req) }
    func index(_ req: Request) throws -> EventLoopFuture<View> {
        return req.view.render(
            "index", InitialPageResponse(
                title: "Swift Playground",
                versions: try VersionGroup.grouped(versions: availableVersions()),
                stableVersion: stableVersion(),
                latestVersion: try latestVersion(),
                codeSnippet: defaultCodeSnippet,
                ogpImageUrl: "./default_ogp.jpeg",
                packageInfo: swiftPackageInfo(app)
            )
        )
    }

    app.get(":id") { req -> EventLoopFuture<Response> in
        if let path = req.parameters.get("id"), let id = try SharedLink.id(from: path) {
            let promise = req.eventLoop.makePromise(of: Response.self)
            try SharedLink.content(client: req.client, id: id.replacingOccurrences(of: ".png", with: ""))
                .whenComplete {
                    switch $0 {
                    case .success(let content):
                        do {
                            if let content = content {
                                let code = content.fields.shared_link.mapValue.fields.content.stringValue
                                let swiftVersion = content.fields.shared_link.mapValue.fields.swift_version.stringValue
                                try handleImportContent(req, promise, id, code, swiftVersion)
                            } else {
                                promise.fail(Abort(.notFound))
                            }
                        } catch {
                            promise.fail(Abort(.internalServerError))
                        }
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            return promise.futureResult
        } else if let path = req.parameters.get("id"), let id = try Gist.id(from: path) {
            let promise = req.eventLoop.makePromise(of: Response.self)
            Gist.content(client: req.client, id: id.replacingOccurrences(of: ".png", with: ""))
                .whenComplete{
                    switch $0 {
                    case .success(let content):
                        do {
                            if let content = content {
                                let code = Array(content.files.values)[0].content
                                try handleImportContent(req, promise, id, code, nil)
                            } else {
                                promise.fail(Abort(.notFound))
                            }
                        } catch {
                            promise.fail(Abort(.internalServerError))
                        }
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            return promise.futureResult
        } else {
            throw Abort(.notFound)
        }
    }

    app.get(":id", "embedded") { req -> EventLoopFuture<Response> in
        let foldRanges: [FoldRange] = req.query[[String].self, at: "fold"]?.compactMap {
            let lines = $0.split(separator: "-")
            guard lines.count == 2 else { return nil }
            guard let start = Int(lines[0]), let end = Int(lines[1]) else { return nil }
            guard start <= end else { return nil }
            return FoldRange(start: start, end: end)
        } ?? []

        if let path = req.parameters.get("id"), let id = try SharedLink.id(from: path) {
            let promise = req.eventLoop.makePromise(of: Response.self)
            try SharedLink.content(client: req.client, id: id)
                .whenComplete {
                    switch $0 {
                    case .success(let content):
                        do {
                            if let content = content {
                                let code = content.fields.shared_link.mapValue.fields.content.stringValue
                                let swiftVersion = content.fields.shared_link.mapValue.fields.swift_version.stringValue
                                try handleEmbeddedContent(req, promise, id, code, swiftVersion, foldRanges)
                            } else {
                                promise.fail(Abort(.notFound))
                            }
                        } catch {
                            promise.fail(Abort(.internalServerError))
                        }
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            return promise.futureResult
        } else if let path = req.parameters.get("id"), let id = try Gist.id(from: path) {
            let promise = req.eventLoop.makePromise(of: Response.self)
            Gist.content(client: req.client, id: id)
                .whenComplete{
                    switch $0 {
                    case .success(let content):
                        do {
                            if let content = content {
                                let code = Array(content.files.values)[0].content
                                try handleEmbeddedContent(req, promise, id, code, nil, foldRanges)
                            } else {
                                promise.fail(Abort(.notFound))
                            }
                        } catch {
                            promise.fail(Abort(.internalServerError))
                        }
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            return promise.futureResult
        } else {
            throw Abort(.notFound)
        }
    }

    app.on(.POST, "run", body: .collect(maxSize: "10mb")) { (req) -> EventLoopFuture<ExecutionResponse> in
        let parameter = try req.content.decode(ExecutionRequestParameter.self)
        let runner = try Runner(parameter: parameter)

        let promise = req.eventLoop.makePromise(of: ExecutionResponse.self)
        try runner.run(
            application: app,
            onComplete: { (response) in
                promise.succeed(response)
            },
            onTimeout: { (response) in
                promise.succeed(response)
            }
        )

        return promise.futureResult
    }

    app.webSocket("ws", ":nonce", "run") { (req, ws) in
        guard let nonce = req.parameters.get("nonce") else {
            _ = ws.close()
            return
        }

        let timer = DispatchSource.makeTimerSource()
        timer.setEventHandler {
            guard let path = WorkingDirectoryRegistry.shared.get(prefix: nonce) else { return }

            let completedPath = path.appendingPathComponent("completed")
            let stdoutPath = path.appendingPathComponent("stdout")
            let stderrPath = path.appendingPathComponent("stderr")
            let versionPath = path.appendingPathComponent("version")

            guard let version = (try? String(contentsOf: versionPath)) else { return }

            let stdout = (try? String(contentsOf: stdoutPath)) ?? ""
            let stderr = (try? String(contentsOf: stderrPath)) ?? ""

            let encoder = JSONEncoder()
            if let response = try? String(data: encoder.encode(ExecutionResponse(output: stdout, errors: stderr, version: version)), encoding: .utf8) {
                ws.send(response)
            }

            if let _ = (try? String(contentsOf: completedPath)) {
                timer.cancel()
                _ = ws.close()
            }
        }
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.resume()

        _ = ws.onClose.always { _ in
            timer.cancel()
        }
    }

    app.on(.POST, "shared_link", body: .collect(maxSize: "10mb")) { (req) -> EventLoopFuture<[String: String]> in
        let parameter = try req.content.decode(SharedLinkRequestParameter.self)
        let code = parameter.code
        let swiftVersion = parameter.toolchain_version

        guard let id = Base32.encoode(bytes: convertHexToBytes(UUID().uuidString.replacingOccurrences(of: "-", with: "")))?.lowercased() else { throw Abort(.internalServerError) }

        let promise = req.eventLoop.makePromise(of: [String: String].self)

        try Firestore.createDocument(client: req.client, id: id, code: parameter.code, swiftVersion: swiftVersion)
            .whenComplete {
                switch $0 {
                case .success:
                    try? ShareImage.image(client: req.client, from: code)
                        .whenSuccess {
                            guard let buffer = $0 else { return }
                            cache.setObject(buffer, forKey: "/\(id).png")
                        }
                    promise.succeed(
                        ["swift_version": swiftVersion,
                        "content": code,
                        "url": "https://swiftfiddle.com/\(id)",
                        ]
                    )
                case .failure(let error):
                    promise.fail(error)
                }
            }

        return promise.futureResult
    }

    app.get("versions") { (req) in try availableVersions() }
}

private func handleImportContent(_ req: Request, _ promise: EventLoopPromise<Response>,
                                 _ id: String, _ code: String, _ swiftVersion: String?) throws {
    let path = req.url.path
    if path.hasSuffix(".png") {
        if let buffer = cache.object(forKey: path) {
            return promise.succeed(Response(status: .ok, headers: ["Content-Type": "image/png"], body: Response.Body(buffer: buffer)))
        }
        return try ShareImage.image(client: req.client, from: code)
            .flatMapThrowing {
                guard let buffer = $0 else { throw Abort(.notFound) }
                return Response(status: .ok, headers: ["Content-Type": "image/png"], body: Response.Body(buffer: buffer))
            }
            .cascade(to: promise)
    } else {
        return req.view.render(
            "index", InitialPageResponse(
                title: "Swift Playground",
                versions: try VersionGroup.grouped(versions: availableVersions()),
                stableVersion: swiftVersion ?? stableVersion(),
                latestVersion: try latestVersion(),
                codeSnippet: code,
                ogpImageUrl: "https://swiftfiddle.com/\(id).png",
                packageInfo: swiftPackageInfo(req.application)
            )
        )
        .encodeResponse(for: req)
        .cascade(to: promise)
    }
}

private func handleEmbeddedContent(_ req: Request, _ promise: EventLoopPromise<Response>,
                                   _ id: String, _ code: String, _ swiftVersion: String?,
                                   _ foldRanges: [FoldRange]) throws {
    req.view.render(
        "embedded", EmbeddedPageResponse(
            title: "Swift Playground",
            versions: try VersionGroup.grouped(versions: availableVersions()),
            stableVersion: swiftVersion ?? stableVersion(),
            latestVersion: try latestVersion(),
            codeSnippet: code,
            url: "https://swiftfiddle.com/\(id)",
            foldRanges: foldRanges
        )
    )
    .encodeResponse(for: req)
    .cascade(to: promise)
}

private func swiftPackageInfo(_ app: Application) -> [PackageInfo] {
    let packagePath = URL(fileURLWithPath: "\(app.directory.resourcesDirectory)Views/Package.json")
    let decoder = JSONDecoder()
    do {
        let package = try decoder.decode(Package.self, from: Data(contentsOf: packagePath))
        guard let target = package.targets.first else { return [] }
        return zip(package.dependencies, target.dependencies).compactMap { (dependency, target) -> PackageInfo? in
            guard let product = target.product.first, let productName = product else { return nil }
            guard let range = dependency.requirement.range.first else { return nil }
            return PackageInfo(
                url: dependency.url,
                name: dependency.name,
                productName: productName,
                version: range.lowerBound
            )
        }

    } catch {
        return []
    }
}

private let defaultCodeSnippet = #"""
import Foundation

func greet(_ something: String) -> String {
  let greeting = "Hello, " + something + "!"
  return greeting
}

// Prints "Hello, World!"
print(greet("World"))

// Prints "Hello, Swift!"
print(greet("Swift"))

"""#
