import Foundation

/// One spreadsheet cell, straight off the OOXML wire. `text` is always the
/// literal cell text -- shared-string content, or the `<v>` element's raw
/// text for numeric/date-serial cells -- never parsed or interpreted here.
/// `CONTRACT.md` §11.5's "raw is never lost" rule starts at this layer.
public struct XLSXCell: Equatable {
    public let text: String
    public let styleIndex: Int
    public let isString: Bool
}

public enum XLSXWorkbookError: Error, Equatable {
    case missingPart(String)
    case malformedXML(part: String)
    case noSheetsDeclared
}

/// CONTRACT-M7.md §3.2: the OOXML parsing layer, sitting on top of
/// `ArchiveReading`. A line-for-line port of `migrate.py`'s `load_workbook`
/// (see that function's comments for the source-of-truth reasoning behind
/// each parsing decision), except number-format categorization goes through
/// `XLSXNumberFormat`'s formatCode-string matching instead of hardcoded
/// numFmtIds -- see that file's header comment for why.
public struct XLSXWorkbook {
    /// Sheet names in the order `xl/workbook.xml` declares them (NOT the
    /// order their `sheetN.xml` parts happen to be numbered -- this
    /// workbook's `Info` sheet is `sheet1.xml` but `Full body` is
    /// `sheet2.xml`, so the two orders coincide here but must not be
    /// assumed to in general).
    public let sheetOrder: [String]
    /// sheetName -> row -> col(1-based, A=1) -> cell. Rows/cells with no
    /// data are simply absent from the map, matching `migrate.py`.
    public let sheets: [String: [Int: [Int: XLSXCell]]]
    private let categoryByStyleIndex: [Int: NumberFormatCategory]

    public func numberFormatCategory(styleIndex: Int) -> NumberFormatCategory {
        categoryByStyleIndex[styleIndex] ?? .general
    }

    public init(archive: ArchiveReading) throws {
        let shared = try Self.parseSharedStrings(archive: archive)
        let categories = try Self.parseStyles(archive: archive)
        let sheetPaths = try Self.parseWorkbookSheetPaths(archive: archive)
        guard !sheetPaths.isEmpty else { throw XLSXWorkbookError.noSheetsDeclared }

        var sheetsDict: [String: [Int: [Int: XLSXCell]]] = [:]
        for (name, path) in sheetPaths {
            sheetsDict[name] = try Self.parseSheetData(archive: archive, path: path, shared: shared)
        }
        self.sheetOrder = sheetPaths.map(\.name)
        self.sheets = sheetsDict
        self.categoryByStyleIndex = categories
    }

    // MARK: - `xl/sharedStrings.xml`

    /// Each `<si>`'s text is the concatenation of ALL its `<t>` descendants
    /// -- rich text splits one logical string across multiple `<r><t>`
    /// runs (e.g. mixed formatting), and taking only the first would
    /// silently truncate it. `sharedStrings.xml` is optional (a workbook
    /// with no string cells at all doesn't need one).
    private static func parseSharedStrings(archive: ArchiveReading) throws -> [String] {
        guard archive.entryNames().contains("xl/sharedStrings.xml") else { return [] }
        let data = try archive.data(forEntry: "xl/sharedStrings.xml")
        let delegate = SharedStringsDelegate()
        try parse(data, part: "xl/sharedStrings.xml", delegate: delegate)
        return delegate.strings
    }

    // MARK: - `xl/styles.xml`

    private static func parseStyles(archive: ArchiveReading) throws -> [Int: NumberFormatCategory] {
        let data = try archive.data(forEntry: "xl/styles.xml")
        let delegate = StylesDelegate()
        try parse(data, part: "xl/styles.xml", delegate: delegate)
        var result: [Int: NumberFormatCategory] = [:]
        for (index, numFmtId) in delegate.cellXfsNumFmtIds.enumerated() {
            if let code = delegate.customFormatCodes[numFmtId] {
                result[index] = XLSXNumberFormat.category(formatCode: code)
            } else {
                result[index] = XLSXNumberFormat.category(builtinNumFmtId: numFmtId)
            }
        }
        return result
    }

    // MARK: - `xl/workbook.xml` + `xl/_rels/workbook.xml.rels`

    /// Sheet name -> actual worksheet part path, resolved through the
    /// relationship id rather than assumed from sheet position.
    private static func parseWorkbookSheetPaths(archive: ArchiveReading) throws -> [(name: String, path: String)] {
        let workbookData = try archive.data(forEntry: "xl/workbook.xml")
        let workbookDelegate = WorkbookSheetsDelegate()
        try parse(workbookData, part: "xl/workbook.xml", delegate: workbookDelegate)

        let relsData = try archive.data(forEntry: "xl/_rels/workbook.xml.rels")
        let relsDelegate = RelationshipsDelegate()
        try parse(relsData, part: "xl/_rels/workbook.xml.rels", delegate: relsDelegate)

        return workbookDelegate.sheets.compactMap { sheet in
            guard let target = relsDelegate.targets[sheet.rId] else { return nil }
            let path = target.hasPrefix("xl/") ? target : "xl/" + target.drop { $0 == "/" }
            return (name: sheet.name, path: path)
        }
    }

    // MARK: - One worksheet's `sheetData`

    private static func parseSheetData(archive: ArchiveReading, path: String, shared: [String]) throws -> [Int: [Int: XLSXCell]] {
        let data = try archive.data(forEntry: path)
        let delegate = SheetDataDelegate(shared: shared)
        try parse(data, part: path, delegate: delegate)
        return delegate.grid
    }

    // MARK: - Shared helpers

    private static func parse(_ data: Data, part: String, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw XLSXWorkbookError.malformedXML(part: part)
        }
    }

    /// "A" -> 1, "Z" -> 26, "AA" -> 27, base-26 with no zero digit.
    static func columnNumber(fromRef ref: String) -> Int? {
        var num = 0
        for scalar in ref.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            num = num * 26 + Int(scalar.value - 64)
        }
        return num > 0 ? num : nil
    }
}

// MARK: - XMLParserDelegate implementations

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var insideSI = false
    private var insideT = false
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si":
            insideSI = true
            currentText = ""
        case "t":
            if insideSI { insideT = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideT { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "t":
            insideT = false
        case "si":
            strings.append(currentText)
            insideSI = false
        default: break
        }
    }
}

private final class StylesDelegate: NSObject, XMLParserDelegate {
    var customFormatCodes: [Int: String] = [:]
    var cellXfsNumFmtIds: [Int] = []
    private var parentStack: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "numFmt":
            if let idText = attributeDict["numFmtId"], let id = Int(idText), let code = attributeDict["formatCode"] {
                customFormatCodes[id] = code
            }
        case "xf":
            // `cellStyleXfs` also contains `<xf>` elements -- only the ones
            // directly under `cellXfs` are what cell `s="N"` indices refer to.
            if parentStack.last == "cellXfs" {
                let numFmtId = Int(attributeDict["numFmtId"] ?? "0") ?? 0
                cellXfsNumFmtIds.append(numFmtId)
            }
        default: break
        }
        parentStack.append(elementName)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !parentStack.isEmpty { parentStack.removeLast() }
    }
}

private final class WorkbookSheetsDelegate: NSObject, XMLParserDelegate {
    var sheets: [(name: String, rId: String)] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "sheet",
              let name = attributeDict["name"],
              let rId = attributeDict["r:id"] else { return }
        sheets.append((name: name, rId: rId))
    }
}

private final class RelationshipsDelegate: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"] else { return }
        targets[id] = target
    }
}

private final class SheetDataDelegate: NSObject, XMLParserDelegate {
    private let shared: [String]
    init(shared: [String]) { self.shared = shared }

    var grid: [Int: [Int: XLSXCell]] = [:]

    private var currentRow: Int?
    private var currentRowCells: [Int: XLSXCell] = [:]

    private var currentCol: Int?
    private var currentStyle = 0
    private var currentType: String?

    private var insideV = false
    private var vBuffer = ""
    private var currentVText: String?

    private var insideIS = false
    private var insideIST = false
    private var isTBuffer = ""
    private var currentIsText: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            if let ref = attributeDict["r"], let num = Int(ref) {
                currentRow = num
                currentRowCells = [:]
            }
        case "c":
            currentCol = XLSXWorkbook.columnNumber(fromRef: attributeDict["r"] ?? "")
            currentStyle = Int(attributeDict["s"] ?? "0") ?? 0
            currentType = attributeDict["t"]
            currentVText = nil
            currentIsText = nil
        case "v":
            insideV = true
            vBuffer = ""
        case "is":
            insideIS = true
            currentIsText = ""
        case "t":
            if insideIS {
                insideIST = true
                isTBuffer = ""
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideV { vBuffer += string }
        else if insideIST { isTBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v":
            insideV = false
            currentVText = vBuffer
        case "t":
            if insideIST {
                currentIsText = (currentIsText ?? "") + isTBuffer
                insideIST = false
            }
        case "is":
            insideIS = false
        case "c":
            finalizeCell()
        case "row":
            if let row = currentRow, !currentRowCells.isEmpty {
                grid[row] = currentRowCells
            }
            currentRow = nil
        default: break
        }
    }

    private func finalizeCell() {
        defer {
            currentCol = nil
            currentType = nil
            currentVText = nil
            currentIsText = nil
        }
        guard let col = currentCol, currentRow != nil else { return }
        let cell: XLSXCell?
        switch currentType {
        case "inlineStr":
            cell = currentIsText.map { XLSXCell(text: $0, styleIndex: currentStyle, isString: true) }
        case "s":
            if let vText = currentVText, let index = Int(vText), shared.indices.contains(index) {
                cell = XLSXCell(text: shared[index], styleIndex: currentStyle, isString: true)
            } else {
                cell = nil
            }
        case "str":
            cell = currentVText.map { XLSXCell(text: $0, styleIndex: currentStyle, isString: true) }
        default:
            // No `t` attribute, or `t="n"`: numeric/date-serial cell. The
            // literal `<v>` text is kept verbatim (e.g. "45516"), never
            // parsed here -- §8.2 reconstruction happens downstream.
            cell = currentVText.map { XLSXCell(text: $0, styleIndex: currentStyle, isString: false) }
        }
        if let cell {
            currentRowCells[col] = cell
        }
    }
}
