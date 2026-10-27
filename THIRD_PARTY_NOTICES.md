# Third-party notices

Diorama is licensed under the Apache License 2.0 (see `LICENSE`). It includes or links the following components:

| Component | Version | License | Use |
|---|---|---|---|
| [SwiftNIO](https://github.com/apple/swift-nio) | 2.104.0 | Apache-2.0 | Gateway HTTP server |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | CLI |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.4 | Apache-2.0 | SwiftNIO dependency |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 | SwiftNIO dependency |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 | SwiftNIO dependency |
| SQLite | macOS system library | Public domain | Storage (linked from the OS, not bundled) |

The README's diagrams (`docs/assets/diagrams/`) use these, outside the app itself:

| Component | Version | License | Use |
|---|---|---|---|
| [Excalifont](https://github.com/excalidraw/excalidraw/tree/master/packages/excalidraw/fonts/Excalifont) (Latin subset) | 1.000 | SIL Open Font License 1.1 | Embedded in the diagram SVGs; the font file and its license are in `scripts/diagrams/fonts/` |
| [rough.js](https://github.com/rough-stuff/rough) | 4.6.6 | MIT | Draws the hand-drawn strokes when the diagrams are generated (`scripts/diagrams`); not included in Diorama |

Excalifont © 2024 Excalidraw (based on Virgil by Your Own Font Foundry, modified by Ján Filípek / DizajnDesign). "Excalifont" is a trademark of Excalidraw. The diagrams imitate Excalidraw's drawing style; they aren't made or endorsed by Excalidraw.

The Apache-2.0 components are © Apple Inc. and the Swift project authors. They are distributed under the Apache License 2.0, with the Runtime Library Exception where their license files apply it. Their license files are in each package's repository.

"Claude", "Claude Code" and "Anthropic" are trademarks of Anthropic, PBC. Diorama is an independent project and isn't affiliated with or endorsed by Anthropic.
