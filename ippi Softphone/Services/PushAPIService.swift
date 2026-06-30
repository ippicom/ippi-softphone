//
//  PushAPIService.swift
//  ippi Softphone
//
//  Created by ippi on 19/02/2026.
//

import Foundation

// MARK: - Errors

enum PushAPIError: LocalizedError {
    case serverError(String)
    case invalidResponse
    case networkError(Error)
    case missingTokenOrCredentials

    var errorDescription: String? {
        switch self {
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidResponse:
            return "Invalid server response"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .missingTokenOrCredentials:
            return "Missing push token or credentials"
        }
    }
}

// MARK: - Service

final class PushAPIService: Sendable {
    static let shared = PushAPIService()

    private init() {}

    /// Register push tokens with the ippi server
    func enablePush(login: String, password: String, voipToken: String, standardToken: String) async throws {
        let hash = Secrets.computePushHash(voipToken: voipToken, login: login, password: password)

        let params: [(String, String)] = [
            ("login", login),
            ("voipToken", voipToken),
            ("standardToken", standardToken),
            ("hash", hash)
        ]

        guard let url = URL(string: Secrets.PushAPI.baseURL + Secrets.PushAPI.enablePath) else {
            throw PushAPIError.invalidResponse
        }
        try await performRequest(url: url, params: params)
        Log.pushKit.success("Push tokens registered with server")
    }

    /// Unregister push tokens from the ippi server
    func disablePush(login: String, password: String, voipToken: String) async throws {
        let hash = Secrets.computePushHash(voipToken: voipToken, login: login, password: password)

        let params: [(String, String)] = [
            ("login", login),
            ("voipToken", voipToken),
            ("hash", hash)
        ]

        guard let url = URL(string: Secrets.PushAPI.baseURL + Secrets.PushAPI.disablePath) else {
            throw PushAPIError.invalidResponse
        }
        try await performRequest(url: url, params: params)
        Log.pushKit.success("Push tokens unregistered from server")
    }

    // MARK: - Private

    /// Characters allowed in form-urlencoded values (RFC 3986 unreserved set).
    /// Notably excludes `=`, `&`, `+`, and other reserved characters.
    private static let formURLEncodedAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Perform a POST request with form-urlencoded body
    private func performRequest(url: URL, params: [(String, String)]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Secrets.PushAPI.appHeader, forHTTPHeaderField: "X-APP")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body = params
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.formURLEncodedAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: Self.formURLEncodedAllowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        Log.pushKit.call("POST \(url.absoluteString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PushAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw PushAPIError.serverError("HTTP \(httpResponse.statusCode): \(body)")
        }

        // Parse JSON response: {"code":"OK","data":"OK"}
        struct APIResponse: Decodable {
            let code: String
        }

        do {
            let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
            guard apiResponse.code == "OK" else {
                throw PushAPIError.serverError(apiResponse.code)
            }
        } catch let error as PushAPIError {
            throw error
        } catch {
            throw PushAPIError.invalidResponse
        }
    }
}
