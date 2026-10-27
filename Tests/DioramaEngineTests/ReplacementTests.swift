import DioramaCore
import DioramaEngine
import Foundation
import Testing

@Suite struct ReplacementTests {
    func apply(_ r: [Replacement], _ texts: [String]) -> Redactor.Result { Redactor.apply([], replacements: r, to: texts) }

    @Test func replacesEveryOccurrenceLiterally() {
        let r = apply([Replacement(find: "30 derece", with: "5 derece")], ["Bugün 30 derece. Yarın da 30 derece."])
        #expect(r.texts == ["Bugün 5 derece. Yarın da 5 derece."])
        #expect(r.summary == "replaced “30 derece” → “5 derece” ×2")
        // Regex characters in a literal find, and $ in a literal replacement, stay literal.
        #expect(apply([Replacement(find: "a.b (x)", with: "$1 cost")], ["a.b (x) and aXb (x)"]).texts == ["$1 cost and aXb (x)"])
    }

    @Test func optionsWholeWordsCaseFirstOnlyAndRegex() {
        #expect(apply([Replacement(find: "30", with: "5", wholeWord: true)], ["30 and 300 and 30."]).texts == ["5 and 300 and 5."])
        #expect(apply([Replacement(find: "derece", with: "°", ignoreCase: true)], ["Derece DERECE derece"]).texts == ["° ° °"])
        #expect(apply([Replacement(find: "x", with: "y", firstOnly: true)], ["a", "x x", "x"]).texts == ["a", "y x", "x"], "first in the whole result")
        #expect(apply([Replacement(find: #"v(\d+)\.(\d+)"#, with: "v$1.9", regex: true)], ["v2.3 and v10.1"]).texts == ["v2.9 and v10.9"])
        #expect(apply([Replacement(find: "missing", with: "x")], ["nothing here"]).total == 0)
    }

    @Test func redactionRunsFirst() {
        let r = Redactor.apply([RedactSpec(presets: [], patterns: ["secret-[0-9]+"])], replacements: [Replacement(find: "secret", with: "public")],
                               to: ["secret-42 and secret"])
        #expect(r.texts == ["[REDACTED:custom] and public"])
        #expect(r.summary == "redacted 1 match (custom ×1); replaced “secret” → “public” ×1")
    }
}

@Suite struct LockdownMatcherTests {
    @Test func findsNetworkCommandsAnywhereInAShellLine() {
        let l = LockdownPreset.network
        for (cmd, program) in [("curl https://x", "curl"), ("cd app && curl -s x", "curl"), ("/usr/bin/curl x", "curl"), ("FOO=1 sudo wget x", "wget"),
                               ("cat f | nc host 80", "nc"), ("echo $(curl x)", "curl"), ("time curl x", "curl"), ("(lynx -dump x)", "lynx")] {
            #expect(l.blockedProgram(in: cmd) == program, "\(cmd)")
        }
        for cmd in ["echo curl", "grep curl notes.txt", "git status", "ls -la", "python3 script.py"] {
            #expect(l.blockedProgram(in: cmd) == nil, "\(cmd)")
        }
        #expect(LockdownPreset.none.blockedProgram(in: "curl x") == nil)
    }
}
