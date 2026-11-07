import Foundation

/// Presentation only. Persisted category IDs, transcription language codes and transcript text
/// are deliberately not translated. Interpolated messages retain their arguments verbatim.
enum Localization {
    static let translations:[String:String] = {
        guard let url = Bundle.main.url(forResource:"Translations",withExtension:"json"),
              let data = try? Data(contentsOf:url),
              let values = try? JSONDecoder().decode([String:String].self,from:data) else {return [:]}
        return values
    }()
    private static let placeholders = try! NSRegularExpression(pattern:"\\{([0-9]+)\\}")
    private static let templates:[(NSRegularExpression,String,[String])] = translations.compactMap {source,target in
        let string = source as NSString
        let matches = placeholders.matches(in:source,range:NSRange(location:0,length:string.length))
        guard !matches.isEmpty else {return nil}
        var pattern = "^";var cursor = 0;var indices:[String] = []
        for match in matches {
            pattern += NSRegularExpression.escapedPattern(for:string.substring(with:NSRange(location:cursor,length:match.range.location-cursor)))
            pattern += "([\\s\\S]*?)";indices.append(string.substring(with:match.range(at:1)))
            cursor = NSMaxRange(match.range)
        }
        pattern += NSRegularExpression.escapedPattern(for:string.substring(from:cursor))+"$"
        guard let regex = try? NSRegularExpression(pattern:pattern) else {return nil}
        return (regex,target,indices)
    }
    static func text(_ source:String,language:String? = nil) -> String {
        let language = language ?? Bundle.main.preferredLocalizations.first ?? "en"
        guard !language.hasPrefix("zh") else {return source}
        if let exact = translations[source] {return exact}
        let string = source as NSString
        for (regex,target,indices) in templates {
            guard let match = regex.firstMatch(in:source,range:NSRange(location:0,length:string.length)) else {continue}
            var values:[String:String] = [:]
            for (index,key) in indices.enumerated() {values[key] = string.substring(with:match.range(at:index+1))}
            let template = target as NSString;var output = "";var cursor = 0
            for placeholder in placeholders.matches(in:target,range:NSRange(location:0,length:template.length)) {
                output += template.substring(with:NSRange(location:cursor,length:placeholder.range.location-cursor))
                output += values[template.substring(with:placeholder.range(at:1))] ?? template.substring(with:placeholder.range)
                cursor = NSMaxRange(placeholder.range)
            }
            return output+template.substring(from:cursor)
        }
        // Historical error messages can contain a localized prefix and an underlying OS error.
        for prefix in translations.keys.sorted(by:{$0.count > $1.count}) where (prefix.hasSuffix("：") || prefix.hasSuffix("\n")) && !prefix.contains("{0}") && source.hasPrefix(prefix) {
            return translations[prefix]!+String(source.dropFirst(prefix.count))
        }
        return source
    }
}
func L(_ text:String) -> String {Localization.text(text)}
