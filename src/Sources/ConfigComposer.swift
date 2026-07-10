import Foundation

struct ConfigProviderAuthRecord: Equatable {
    let providerID: String
    let apiKey: String
    let isDisabled: Bool
}

enum ConfigComposer {
    static let uiMetadataKeys: Set<String> = ["display-name", "help-text", "icon-system"]
    static let runtimeEditableTopLevelKeys: Set<String> = ["api-keys"]
    
    static func composeAdditiveBaseConfig(bundledRoot: [String: Any], userRoot: [String: Any]?) -> [String: Any] {
        guard let userRoot else {
            return bundledRoot
        }
        return mergeDictionary(bundledRoot, overlaidWith: userRoot)
    }

    static func preservingRuntimeEditableTopLevelKeys(
        in root: [String: Any],
        from runtimeRoot: [String: Any]?
    ) -> [String: Any] {
        guard let runtimeRoot else {
            return root
        }

        var mergedRoot = root
        for key in runtimeEditableTopLevelKeys where mergedRoot[key] == nil {
            if let runtimeValue = runtimeRoot[key] {
                mergedRoot[key] = runtimeValue
            }
        }
        return mergedRoot
    }
    
    static func parseCustomProviders(
        from root: [String: Any],
        reservedProviderIDs: Set<String>
    ) -> [CustomProviderDefinition] {
        stringKeyedDictionaryArray(root["openai-compatibility"])
            .compactMap { entry in
                guard let providerID = normalizedProviderID(from: entry),
                      !reservedProviderIDs.contains(providerID) else {
                    return nil
                }
                
                let modelAliases = stringKeyedDictionaryArray(entry["models"])
                    .compactMap { model in
                        (model["alias"] as? String) ?? (model["name"] as? String)
                    }
                return CustomProviderDefinition(
                    id: providerID,
                    title: (entry["display-name"] as? String) ?? CustomProviderDefinition.defaultTitle(for: providerID),
                    baseURL: normalizedString(entry["base-url"]) ?? "",
                    helpText: entry["help-text"] as? String,
                    iconSystemName: entry["icon-system"] as? String,
                    modelAliases: modelAliases,
                    inlineAPIKeys: deduplicatedAPIKeys(from: entry)
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func validateCustomProviders(
        in root: [String: Any],
        reservedProviderIDs: Set<String>
    ) -> [String] {
        guard let rawOpenAICompatibility = root["openai-compatibility"] else {
            return []
        }
        guard let entries = rawOpenAICompatibility as? [Any] else {
            return ["openai-compatibility must be an array of provider mappings."]
        }

        var errors: [String] = []
        var seenProviderIDs: Set<String> = []

        for (index, rawEntry) in entries.enumerated() {
            let path = "openai-compatibility[\(index)]"

            guard let entry = stringKeyedDictionary(rawEntry) else {
                errors.append("\(path) must be a mapping.")
                continue
            }

            guard let rawProviderName = entry["name"] as? String else {
                errors.append("\(path) must define a string name.")
                continue
            }

            guard let providerID = normalizedString(rawProviderName) else {
                errors.append("\(path) must define a non-empty name.")
                continue
            }

            guard rawProviderName == providerID else {
                errors.append("Provider name '\(rawProviderName)' must not include leading or trailing whitespace.")
                continue
            }

            if seenProviderIDs.contains(providerID) {
                errors.append("Duplicate openai-compatibility provider '\(providerID)' is not allowed.")
            } else {
                seenProviderIDs.insert(providerID)
            }

            if reservedProviderIDs.contains(providerID),
               providerID != ProviderCatalog.managedZAIProviderName,
               providerID != ProviderCatalog.managedDevinProviderName {
                errors.append("Provider '\(providerID)' is reserved and cannot be declared under openai-compatibility.")
                continue
            }

            if let modelsValue = entry["models"] {
                errors.append(contentsOf: validateMappingArray(modelsValue, path: "\(path).models"))
            }

            if let apiKeyEntriesValue = entry["api-key-entries"] {
                if let apiKeyEntries = apiKeyEntriesValue as? [Any] {
                    for (apiKeyIndex, rawAPIKeyEntry) in apiKeyEntries.enumerated() {
                        let apiKeyPath = "\(path).api-key-entries[\(apiKeyIndex)]"
                        guard let apiKeyEntry = stringKeyedDictionary(rawAPIKeyEntry) else {
                            errors.append("\(apiKeyPath) must be a mapping.")
                            continue
                        }
                        guard normalizedString(apiKeyEntry["api-key"]) != nil else {
                            errors.append("\(apiKeyPath) must define a non-empty api-key.")
                            continue
                        }
                    }
                } else {
                    errors.append("\(path).api-key-entries must be an array of mappings.")
                }
            }

            if providerID == ProviderCatalog.managedZAIProviderName
                || providerID == ProviderCatalog.managedDevinProviderName {
                continue
            }

            guard normalizedString(entry["base-url"]) != nil else {
                errors.append("Custom provider '\(providerID)' must define a non-empty base-url.")
                continue
            }
        }

        return errors
    }
    
    static func composeRuntimeConfig(
        baseRoot: [String: Any],
        reservedCustomProviderKeys: Set<String>,
        disabledCustomProviderIDs: Set<String>,
        disabledOAuthProviderKeys: [String],
        zaiAPIKeys: [String],
        customProviderAuthRecords: [ConfigProviderAuthRecord],
        includeManagedZAIProvider: Bool,
        managedZAIProviderName: String = "zai",
        includeManagedDevinProvider: Bool = true,
        managedDevinProviderName: String = "devin"
    ) -> [String: Any] {
        var mergedRoot = baseRoot
        
        let oauthExcludedModels = buildOAuthExcludedModels(
            from: mergedRoot["oauth-excluded-models"],
            disabledOAuthProviderKeys: disabledOAuthProviderKeys
        )
        if let oauthExcludedModels {
            mergedRoot["oauth-excluded-models"] = oauthExcludedModels
        } else {
            mergedRoot.removeValue(forKey: "oauth-excluded-models")
        }
        
        let managedCustomProviderIDs = Set(
            parseCustomProviders(from: baseRoot, reservedProviderIDs: reservedCustomProviderKeys).map(\.id)
        )
        let authEntriesByProviderID = Dictionary(
            grouping: customProviderAuthRecords.filter { !$0.isDisabled },
            by: \.providerID
        ).mapValues { records in
            records.map { ["api-key": $0.apiKey] }
        }
        
        var mergedOpenAICompatibility: [[String: Any]] = []
        var managedZAIBaseEntry: [String: Any]?
        var managedDevinBaseEntry: [String: Any]?
        for entry in stringKeyedDictionaryArray(mergedRoot["openai-compatibility"]) {
            guard let providerName = normalizedProviderID(from: entry) else {
                continue
            }

            var sanitizedEntry = stripCustomProviderUIMetadata(from: entry)
            sanitizedEntry["name"] = providerName
            if providerName == managedZAIProviderName {
                managedZAIBaseEntry = sanitizedEntry
                continue
            }
            if providerName == managedDevinProviderName {
                managedDevinBaseEntry = sanitizedEntry
                continue
            }

            if managedCustomProviderIDs.contains(providerName) {
                if disabledCustomProviderIDs.contains(providerName) {
                    continue
                }

                let inlineEntries = apiKeyEntries(from: entry)
                let authEntries = authEntriesByProviderID[providerName] ?? []
                let effectiveEntries = deduplicatedAPIKeyEntries(inlineEntries + authEntries)
                guard !effectiveEntries.isEmpty else {
                    continue
                }
                sanitizedEntry["api-key-entries"] = effectiveEntries
            }

            mergedOpenAICompatibility.append(sanitizedEntry)
        }

        if includeManagedZAIProvider {
            let managedZAIEntry = makeZAIProviderEntry(
                baseEntry: managedZAIBaseEntry,
                apiKeys: zaiAPIKeys
            )
            if !apiKeyEntries(from: managedZAIEntry).isEmpty {
                mergedOpenAICompatibility.append(managedZAIEntry)
            }
        }

        if includeManagedDevinProvider {
            let managedDevinEntry = makeDevinProviderEntry(
                baseEntry: managedDevinBaseEntry
            )
            if managedDevinEntry["base-url"] != nil {
                mergedOpenAICompatibility.append(managedDevinEntry)
            }
        }
        
        if mergedOpenAICompatibility.isEmpty {
            mergedRoot.removeValue(forKey: "openai-compatibility")
        } else {
            mergedRoot["openai-compatibility"] = mergedOpenAICompatibility
        }
        
        return mergedRoot
    }
    
    static func stringKeyedDictionary(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? [AnyHashable: Any] {
            var stringDictionary: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                guard let stringKey = key as? String else {
                    continue
                }
                stringDictionary[stringKey] = nestedValue
            }
            return stringDictionary
        }
        return nil
    }
    
    static func stringKeyedDictionaryArray(_ value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else {
            return []
        }
        return array.compactMap { stringKeyedDictionary($0) }
    }

    static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? String }
        }
        return []
    }

    static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isOAuthProviderWildcardExcluded(_ oauthProviderKey: String, in root: [String: Any]) -> Bool {
        let exclusions = stringKeyedDictionary(root["oauth-excluded-models"] ?? [:]) ?? [:]
        return stringArray(exclusions[oauthProviderKey]).contains("*")
    }
    
    private static func mergeDictionary(_ base: [String: Any], overlaidWith overlay: [String: Any]) -> [String: Any] {
        var merged = base
        
        for (key, overlayValue) in overlay {
            if key == "openai-compatibility" {
                if let overlayArray = overlayValue as? [Any] {
                    guard !overlayArray.isEmpty else {
                        continue
                    }

                    let overlayEntries = overlayArray.compactMap { stringKeyedDictionary($0) }
                    if overlayEntries.isEmpty {
                        merged[key] = overlayValue
                    } else {
                        let baseEntries = stringKeyedDictionaryArray(merged[key])
                        merged[key] = mergeNamedEntries(base: baseEntries, overlay: overlayEntries)
                    }
                } else {
                    merged[key] = overlayValue
                }
                continue
            }
            
            if let overlayDictionary = stringKeyedDictionary(overlayValue),
               let baseDictionary = merged[key].flatMap(stringKeyedDictionary) {
                merged[key] = mergeDictionary(baseDictionary, overlaidWith: overlayDictionary)
            } else {
                merged[key] = overlayValue
            }
        }
        
        return merged
    }
    
    private static func mergeNamedEntries(base: [[String: Any]], overlay: [[String: Any]]) -> [[String: Any]] {
        var mergedEntries = base
        var indexByName: [String: Int] = [:]
        
        for (index, entry) in base.enumerated() {
            if let name = normalizedProviderID(from: entry) {
                indexByName[name] = index
                if (mergedEntries[index]["name"] as? String) != name {
                    mergedEntries[index]["name"] = name
                }
            }
        }
        
        for overlayEntry in overlay {
            guard let name = normalizedProviderID(from: overlayEntry) else {
                mergedEntries.append(overlayEntry)
                continue
            }

            var canonicalOverlayEntry = overlayEntry
            canonicalOverlayEntry["name"] = name
            
            if let existingIndex = indexByName[name] {
                let existingEntry = mergedEntries[existingIndex]
                mergedEntries[existingIndex] = mergeDictionary(existingEntry, overlaidWith: canonicalOverlayEntry)
            } else {
                indexByName[name] = mergedEntries.count
                mergedEntries.append(canonicalOverlayEntry)
            }
        }
        
        return mergedEntries
    }
    
    private static func apiKeyEntries(from entry: [String: Any]) -> [[String: String]] {
        stringKeyedDictionaryArray(entry["api-key-entries"]).compactMap { keyEntry in
            guard let apiKey = normalizedString(keyEntry["api-key"]) else {
                return nil
            }
            return ["api-key": apiKey]
        }
    }

    private static func deduplicatedAPIKeys(from entry: [String: Any]) -> [String] {
        deduplicatedAPIKeyEntries(apiKeyEntries(from: entry)).compactMap { $0["api-key"] }
    }
    
    private static func deduplicatedAPIKeyEntries(_ entries: [[String: String]]) -> [[String: String]] {
        var seen: Set<String> = []
        return entries.filter { entry in
            guard let apiKey = entry["api-key"] else {
                return false
            }
            if seen.contains(apiKey) {
                return false
            }
            seen.insert(apiKey)
            return true
        }
    }
    
    private static func stripCustomProviderUIMetadata(from entry: [String: Any]) -> [String: Any] {
        var sanitized = entry
        for key in uiMetadataKeys {
            sanitized.removeValue(forKey: key)
        }
        return sanitized
    }
    
    private static func buildOAuthExcludedModels(
        from value: Any?,
        disabledOAuthProviderKeys: [String]
    ) -> [String: Any]? {
        var merged = stringKeyedDictionary(value ?? [:]) ?? [:]
        for providerKey in disabledOAuthProviderKeys.sorted() {
            merged[providerKey] = ["*"]
        }
        return merged.isEmpty ? nil : merged
    }
    
    private static func makeZAIProviderEntry(baseEntry: [String: Any]?, apiKeys: [String]) -> [String: Any] {
        var entry = stripCustomProviderUIMetadata(from: baseEntry ?? [:])
        entry["name"] = "zai"

        if normalizedString(entry["base-url"]) == nil {
            entry["base-url"] = "https://api.z.ai/api/coding/paas/v4"
        }

        let inlineEntries = apiKeyEntries(from: entry)
        entry["api-key-entries"] = deduplicatedAPIKeyEntries(
            inlineEntries + apiKeys.map { ["api-key": $0] }
        )

        if stringKeyedDictionaryArray(entry["models"]).isEmpty {
            entry["models"] = defaultZAIModels()
        }

        return entry
    }

    private static func makeDevinProviderEntry(baseEntry: [String: Any]?) -> [String: Any] {
        var entry = stripCustomProviderUIMetadata(from: baseEntry ?? [:])
        entry["name"] = "devin"

        if normalizedString(entry["base-url"]) == nil {
            entry["base-url"] = "http://127.0.0.1:8419/v1"
        }

        // The Devin bridge doesn't require API keys in the config —
        // it reads credentials from ~/.devin/credentials.toml directly.
        // We use a placeholder key so CLIProxyAPIPlus will route to it.
        if apiKeyEntries(from: entry).isEmpty {
            entry["api-key-entries"] = [["api-key": "devin-bridge-no-key-needed"]]
        }

        if stringKeyedDictionaryArray(entry["models"]).isEmpty {
            entry["models"] = defaultDevinModels()
        }

        return entry
    }

    private static func defaultDevinModels() -> [[String: String]] {
        // 142 models fetched live from Devin ACP session/new configOptions
        // (2026-07-10). Includes GLM-5.2, Kimi K2.7, Grok 4.5, DeepSeek V4,
        // Claude Opus 4.8, GPT-5.6 Sol/Luna/Terra, SWE-1.7, etc.
        [
            ["name": "claude-opus-4-8-medium", "alias": "devin-claude-opus-4-8-medium"],
            ["name": "claude-opus-4-8-low", "alias": "devin-claude-opus-4-8-low"],
            ["name": "claude-opus-4-8-high", "alias": "devin-claude-opus-4-8-high"],
            ["name": "claude-opus-4-8-xhigh", "alias": "devin-claude-opus-4-8-xhigh"],
            ["name": "claude-opus-4-8-max", "alias": "devin-claude-opus-4-8-max"],
            ["name": "claude-opus-4-8-low-fast", "alias": "devin-claude-opus-4-8-low-fast"],
            ["name": "claude-opus-4-8-medium-fast", "alias": "devin-claude-opus-4-8-medium-fast"],
            ["name": "claude-opus-4-8-high-fast", "alias": "devin-claude-opus-4-8-high-fast"],
            ["name": "claude-opus-4-8-xhigh-fast", "alias": "devin-claude-opus-4-8-xhigh-fast"],
            ["name": "claude-opus-4-8-max-fast", "alias": "devin-claude-opus-4-8-max-fast"],
            ["name": "claude-5-fable-medium", "alias": "devin-claude-5-fable-medium"],
            ["name": "claude-5-fable-low", "alias": "devin-claude-5-fable-low"],
            ["name": "claude-5-fable-high", "alias": "devin-claude-5-fable-high"],
            ["name": "claude-5-fable-xhigh", "alias": "devin-claude-5-fable-xhigh"],
            ["name": "claude-5-fable-max", "alias": "devin-claude-5-fable-max"],
            ["name": "claude-sonnet-5-medium", "alias": "devin-claude-sonnet-5-medium"],
            ["name": "claude-sonnet-5-low", "alias": "devin-claude-sonnet-5-low"],
            ["name": "claude-sonnet-5-high", "alias": "devin-claude-sonnet-5-high"],
            ["name": "claude-sonnet-5-xhigh", "alias": "devin-claude-sonnet-5-xhigh"],
            ["name": "claude-sonnet-5-max", "alias": "devin-claude-sonnet-5-max"],
            ["name": "gpt-5-6-sol-medium", "alias": "devin-gpt-5-6-sol-medium"],
            ["name": "gpt-5-6-sol-none", "alias": "devin-gpt-5-6-sol-none"],
            ["name": "gpt-5-6-sol-low", "alias": "devin-gpt-5-6-sol-low"],
            ["name": "gpt-5-6-sol-high", "alias": "devin-gpt-5-6-sol-high"],
            ["name": "gpt-5-6-sol-xhigh", "alias": "devin-gpt-5-6-sol-xhigh"],
            ["name": "gpt-5-6-sol-max", "alias": "devin-gpt-5-6-sol-max"],
            ["name": "gpt-5-6-sol-none-priority", "alias": "devin-gpt-5-6-sol-none-priority"],
            ["name": "gpt-5-6-sol-low-priority", "alias": "devin-gpt-5-6-sol-low-priority"],
            ["name": "gpt-5-6-sol-medium-priority", "alias": "devin-gpt-5-6-sol-medium-priority"],
            ["name": "gpt-5-6-sol-high-priority", "alias": "devin-gpt-5-6-sol-high-priority"],
            ["name": "gpt-5-6-sol-xhigh-priority", "alias": "devin-gpt-5-6-sol-xhigh-priority"],
            ["name": "gpt-5-6-luna-medium", "alias": "devin-gpt-5-6-luna-medium"],
            ["name": "gpt-5-6-luna-none", "alias": "devin-gpt-5-6-luna-none"],
            ["name": "gpt-5-6-luna-low", "alias": "devin-gpt-5-6-luna-low"],
            ["name": "gpt-5-6-luna-high", "alias": "devin-gpt-5-6-luna-high"],
            ["name": "gpt-5-6-luna-xhigh", "alias": "devin-gpt-5-6-luna-xhigh"],
            ["name": "gpt-5-6-luna-max", "alias": "devin-gpt-5-6-luna-max"],
            ["name": "gpt-5-6-luna-none-priority", "alias": "devin-gpt-5-6-luna-none-priority"],
            ["name": "gpt-5-6-luna-low-priority", "alias": "devin-gpt-5-6-luna-low-priority"],
            ["name": "gpt-5-6-luna-medium-priority", "alias": "devin-gpt-5-6-luna-medium-priority"],
            ["name": "gpt-5-6-luna-high-priority", "alias": "devin-gpt-5-6-luna-high-priority"],
            ["name": "gpt-5-6-luna-xhigh-priority", "alias": "devin-gpt-5-6-luna-xhigh-priority"],
            ["name": "glm-5-2", "alias": "devin-glm-5-2"],
            ["name": "glm-5-2-max", "alias": "devin-glm-5-2-max"],
            ["name": "glm-5-2-1m", "alias": "devin-glm-5-2-1m"],
            ["name": "glm-5-2-max-1m", "alias": "devin-glm-5-2-max-1m"],
            ["name": "glm-5-2-none", "alias": "devin-glm-5-2-none"],
            ["name": "glm-5-2-none-1m", "alias": "devin-glm-5-2-none-1m"],
            ["name": "kimi-k2-7", "alias": "devin-kimi-k2-7"],
            ["name": "swe-1-7", "alias": "devin-swe-1-7"],
            ["name": "swe-1-7-lightning", "alias": "devin-swe-1-7-lightning"],
            ["name": "adaptive", "alias": "devin-adaptive"],
            ["name": "claude-opus-4-7-medium", "alias": "devin-claude-opus-4-7-medium"],
            ["name": "claude-opus-4-7-low", "alias": "devin-claude-opus-4-7-low"],
            ["name": "claude-opus-4-7-high", "alias": "devin-claude-opus-4-7-high"],
            ["name": "claude-opus-4-7-xhigh", "alias": "devin-claude-opus-4-7-xhigh"],
            ["name": "claude-opus-4-7-max", "alias": "devin-claude-opus-4-7-max"],
            ["name": "claude-opus-4-7-low-fast", "alias": "devin-claude-opus-4-7-low-fast"],
            ["name": "claude-opus-4-7-medium-fast", "alias": "devin-claude-opus-4-7-medium-fast"],
            ["name": "claude-opus-4-7-high-fast", "alias": "devin-claude-opus-4-7-high-fast"],
            ["name": "claude-opus-4-7-xhigh-fast", "alias": "devin-claude-opus-4-7-xhigh-fast"],
            ["name": "claude-opus-4-7-max-fast", "alias": "devin-claude-opus-4-7-max-fast"],
            ["name": "gemini-3-5-flash-minimal", "alias": "devin-gemini-3-5-flash-minimal"],
            ["name": "gemini-3-5-flash-low", "alias": "devin-gemini-3-5-flash-low"],
            ["name": "gemini-3-5-flash-medium", "alias": "devin-gemini-3-5-flash-medium"],
            ["name": "gemini-3-5-flash-high", "alias": "devin-gemini-3-5-flash-high"],
            ["name": "gpt-5-6-terra-none", "alias": "devin-gpt-5-6-terra-none"],
            ["name": "gpt-5-6-terra-low", "alias": "devin-gpt-5-6-terra-low"],
            ["name": "gpt-5-6-terra-medium", "alias": "devin-gpt-5-6-terra-medium"],
            ["name": "gpt-5-6-terra-high", "alias": "devin-gpt-5-6-terra-high"],
            ["name": "gpt-5-6-terra-xhigh", "alias": "devin-gpt-5-6-terra-xhigh"],
            ["name": "gpt-5-6-terra-max", "alias": "devin-gpt-5-6-terra-max"],
            ["name": "gpt-5-6-terra-none-priority", "alias": "devin-gpt-5-6-terra-none-priority"],
            ["name": "gpt-5-6-terra-low-priority", "alias": "devin-gpt-5-6-terra-low-priority"],
            ["name": "gpt-5-6-terra-medium-priority", "alias": "devin-gpt-5-6-terra-medium-priority"],
            ["name": "gpt-5-6-terra-high-priority", "alias": "devin-gpt-5-6-terra-high-priority"],
            ["name": "gpt-5-6-terra-xhigh-priority", "alias": "devin-gpt-5-6-terra-xhigh-priority"],
            ["name": "grok-4-5-low", "alias": "devin-grok-4-5-low"],
            ["name": "grok-4-5-medium", "alias": "devin-grok-4-5-medium"],
            ["name": "grok-4-5-high", "alias": "devin-grok-4-5-high"],
            ["name": "claude-opus-4-6", "alias": "devin-claude-opus-4-6"],
            ["name": "claude-opus-4-6-thinking", "alias": "devin-claude-opus-4-6-thinking"],
            ["name": "claude-opus-4-6-1m", "alias": "devin-claude-opus-4-6-1m"],
            ["name": "claude-opus-4-6-thinking-1m", "alias": "devin-claude-opus-4-6-thinking-1m"],
            ["name": "gpt-5-4-none", "alias": "devin-gpt-5-4-none"],
            ["name": "gpt-5-4-low", "alias": "devin-gpt-5-4-low"],
            ["name": "gpt-5-4-medium", "alias": "devin-gpt-5-4-medium"],
            ["name": "gpt-5-4-high", "alias": "devin-gpt-5-4-high"],
            ["name": "gpt-5-4-xhigh", "alias": "devin-gpt-5-4-xhigh"],
            ["name": "gpt-5-4-none-priority", "alias": "devin-gpt-5-4-none-priority"],
            ["name": "gpt-5-4-low-priority", "alias": "devin-gpt-5-4-low-priority"],
            ["name": "gpt-5-4-medium-priority", "alias": "devin-gpt-5-4-medium-priority"],
            ["name": "gpt-5-4-high-priority", "alias": "devin-gpt-5-4-high-priority"],
            ["name": "gpt-5-4-xhigh-priority", "alias": "devin-gpt-5-4-xhigh-priority"],
            ["name": "gpt-5-5-none", "alias": "devin-gpt-5-5-none"],
            ["name": "gpt-5-5-low", "alias": "devin-gpt-5-5-low"],
            ["name": "gpt-5-5-medium", "alias": "devin-gpt-5-5-medium"],
            ["name": "gpt-5-5-high", "alias": "devin-gpt-5-5-high"],
            ["name": "gpt-5-5-xhigh", "alias": "devin-gpt-5-5-xhigh"],
            ["name": "gpt-5-5-none-priority", "alias": "devin-gpt-5-5-none-priority"],
            ["name": "gpt-5-5-low-priority", "alias": "devin-gpt-5-5-low-priority"],
            ["name": "gpt-5-5-medium-priority", "alias": "devin-gpt-5-5-medium-priority"],
            ["name": "gpt-5-5-high-priority", "alias": "devin-gpt-5-5-high-priority"],
            ["name": "gpt-5-5-xhigh-priority", "alias": "devin-gpt-5-5-xhigh-priority"],
            ["name": "gpt-5-4-mini-low", "alias": "devin-gpt-5-4-mini-low"],
            ["name": "gpt-5-4-mini-medium", "alias": "devin-gpt-5-4-mini-medium"],
            ["name": "gpt-5-4-mini-high", "alias": "devin-gpt-5-4-mini-high"],
            ["name": "gpt-5-4-mini-xhigh", "alias": "devin-gpt-5-4-mini-xhigh"],
            ["name": "claude-sonnet-4-6", "alias": "devin-claude-sonnet-4-6"],
            ["name": "claude-sonnet-4-6-thinking", "alias": "devin-claude-sonnet-4-6-thinking"],
            ["name": "claude-sonnet-4-6-1m", "alias": "devin-claude-sonnet-4-6-1m"],
            ["name": "claude-sonnet-4-6-thinking-1m", "alias": "devin-claude-sonnet-4-6-thinking-1m"],
            ["name": "MODEL_GPT_5_2_LOW", "alias": "devin-MODEL_GPT_5_2_LOW"],
            ["name": "MODEL_GPT_5_2_MEDIUM", "alias": "devin-MODEL_GPT_5_2_MEDIUM"],
            ["name": "MODEL_GPT_5_2_NONE", "alias": "devin-MODEL_GPT_5_2_NONE"],
            ["name": "MODEL_GPT_5_2_HIGH", "alias": "devin-MODEL_GPT_5_2_HIGH"],
            ["name": "MODEL_GPT_5_2_XHIGH", "alias": "devin-MODEL_GPT_5_2_XHIGH"],
            ["name": "MODEL_CLAUDE_4_5_OPUS", "alias": "devin-MODEL_CLAUDE_4_5_OPUS"],
            ["name": "MODEL_CLAUDE_4_5_OPUS_THINKING", "alias": "devin-MODEL_CLAUDE_4_5_OPUS_THINKING"],
            ["name": "MODEL_SWE_1_5", "alias": "devin-MODEL_SWE_1_5"],
            ["name": "MODEL_SWE_1_5_SLOW", "alias": "devin-MODEL_SWE_1_5_SLOW"],
            ["name": "MODEL_PRIVATE_11", "alias": "devin-MODEL_PRIVATE_11"],
            ["name": "MODEL_PRIVATE_2", "alias": "devin-MODEL_PRIVATE_2"],
            ["name": "MODEL_PRIVATE_3", "alias": "devin-MODEL_PRIVATE_3"],
            ["name": "gpt-5-3-codex-low", "alias": "devin-gpt-5-3-codex-low"],
            ["name": "gpt-5-3-codex-medium", "alias": "devin-gpt-5-3-codex-medium"],
            ["name": "gpt-5-3-codex-high", "alias": "devin-gpt-5-3-codex-high"],
            ["name": "gpt-5-3-codex-xhigh", "alias": "devin-gpt-5-3-codex-xhigh"],
            ["name": "gpt-5-3-codex-low-priority", "alias": "devin-gpt-5-3-codex-low-priority"],
            ["name": "gpt-5-3-codex-medium-priority", "alias": "devin-gpt-5-3-codex-medium-priority"],
            ["name": "gpt-5-3-codex-high-priority", "alias": "devin-gpt-5-3-codex-high-priority"],
            ["name": "gpt-5-3-codex-xhigh-priority", "alias": "devin-gpt-5-3-codex-xhigh-priority"],
            ["name": "kimi-k2-6", "alias": "devin-kimi-k2-6"],
            ["name": "swe-1-6", "alias": "devin-swe-1-6"],
            ["name": "swe-1-6-fast", "alias": "devin-swe-1-6-fast"],
            ["name": "gemini-3-1-pro-low", "alias": "devin-gemini-3-1-pro-low"],
            ["name": "gemini-3-1-pro-high", "alias": "devin-gemini-3-1-pro-high"],
            ["name": "MODEL_GOOGLE_GEMINI_3_0_FLASH_MINIMAL", "alias": "devin-MODEL_GOOGLE_GEMINI_3_0_FLASH_MINIMAL"],
            ["name": "MODEL_GOOGLE_GEMINI_3_0_FLASH_LOW", "alias": "devin-MODEL_GOOGLE_GEMINI_3_0_FLASH_LOW"],
            ["name": "MODEL_GOOGLE_GEMINI_3_0_FLASH_MEDIUM", "alias": "devin-MODEL_GOOGLE_GEMINI_3_0_FLASH_MEDIUM"],
            ["name": "MODEL_GOOGLE_GEMINI_3_0_FLASH_HIGH", "alias": "devin-MODEL_GOOGLE_GEMINI_3_0_FLASH_HIGH"],
            ["name": "deepseek-v4", "alias": "devin-deepseek-v4"],
        ]
    }

    private static func normalizedProviderID(from entry: [String: Any]) -> String? {
        normalizedString(entry["name"])
    }

    private static func validateMappingArray(_ value: Any, path: String) -> [String] {
        guard let array = value as? [Any] else {
            return ["\(path) must be an array of mappings."]
        }

        var errors: [String] = []
        for (index, rawEntry) in array.enumerated() where stringKeyedDictionary(rawEntry) == nil {
            errors.append("\(path)[\(index)] must be a mapping.")
        }
        return errors
    }

    private static func defaultZAIModels() -> [[String: String]] {
        [
            ["name": "glm-4.7", "alias": "glm-4.7"],
            ["name": "glm-4-plus", "alias": "glm-4-plus"],
            ["name": "glm-4-air", "alias": "glm-4-air"],
            ["name": "glm-4-flash", "alias": "glm-4-flash"]
        ]
    }
}
