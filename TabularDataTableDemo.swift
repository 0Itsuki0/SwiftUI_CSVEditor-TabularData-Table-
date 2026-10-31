//
//  TabularData+Table.swift
//  Demo10
//
//  Created by Itsuki on 2026/10/29.
//

import SwiftUI
import TabularData
import UniformTypeIdentifiers

// MARK: - helper types
nonisolated private struct IdentifiableRow: Identifiable, Equatable {
    static let headerRowIndex = -1
    /// a combination of index, row value, corresponding column
    /// so that, for example, when drag and drop, the position change can be reflected (If simply using Index, the table won't be reloaded in this case).
    var id: String { "\(row.index)_\(row.description)" }
    /// stored index (instead of calculated) to reserve a special index for header row.
    var index: Int
    var row: DataFrame.Row

    init(_ row: DataFrame.Row) {
        self.index = row.index
        self.row = row
    }

    /// create a row for column names (As header row)
    init(colNames: [String]) {
        var cols: [Column<String>] = []
        colNames.forEach { col in
            cols.append(Column(name: col, contents: [col]))
        }
        let name = DataFrame(columns: cols.map({ $0.eraseToAnyColumn() }))
        let headerRow = name.rows[0]
        self.index = Self.headerRowIndex
        self.row = headerRow
    }
}

nonisolated private struct IdentifiableColumn: Identifiable {
    var id: Int { index }
    var index: Int
    var col: AnyColumn

    var name: String {
        col.name
    }

    var type: any Any.Type {
        col.wrappedElementType
    }

    init(_ col: AnyColumn, index: Int) {
        self.index = index
        self.col = col
    }
}

private enum ValueType: String, Identifiable, Hashable, Equatable, CaseIterable
{
    case string
    case int
    case double

    var id: String { rawValue }

    init?(_ type: any Any.Type) {
        if type is Int.Type {
            self = .int
            return
        }
        if type is String.Type {
            self = .string
            return
        }
        if type is Double.Type {
            self = .double
            return
        }
        return nil
    }
}

// MARK: - helper extensions
extension DataFrame.Row {
    /// A custom subscript for keyPath usage.
    /// The built in one does not check whether if the index is out of bound
    /// which causes crash when inserting / deleting columns
    fileprivate subscript(position: Int, safe: Bool = true) -> Any? {
        if position < self.count {
            return self[position]
        } else {
            return nil
        }
    }
}

extension TableColumnCustomization {
    /// Returning: A list of `customizationId` if `explicit` ,`name` if `transient` (columns that does not have  `customizationID(_:) `attached)
    fileprivate var columnOrder: [String] {
        let mirror = Mirror(reflecting: self)
        var currentOrder: [String] = []

        guard
            let columnOrder = mirror.children.first(where: {
                $0.label == "columnOrder"
            })
        else {
            return []
        }

        guard let columnOrder = columnOrder.value as? [Any] else {
            return []
        }

        for col in columnOrder {
            // TableColumnCustomizationID -> `base`
            guard
                let base = Mirror(reflecting: col).children.first(where: {
                    $0.label == "base"
                })?.value,
                // enum `base` -> single child labeled with the case name
                let enumCase = Mirror(reflecting: base).children.first
            else { continue }

            switch enumCase.label {
            /// columns with  `customizationID(_:)`
            /// ex: [explicit: date_1_false]
            case "explicit":
                if let id = enumCase.value as? String {
                    currentOrder.append(id)
                }
            /// columns without  `customizationID(_:)`
            /// ex: [transient: TransientHint(name: " ", id: "DA84CDAB-60B5-44D2-9580-8CEB4E487E11")]
            case "transient":
                // TransientHint struct -> mirror again for `name` / `id`
                let hint = Mirror(reflecting: enumCase.value)
                let name =
                    hint.children.first(where: { $0.label == "name" })?.value
                    as? String
                if let name {
                    currentOrder.append(name)
                }
            default:
                continue
            }
        }

        return currentOrder
    }
}

// MARK: - Transferable for row drag/drop and export
private struct TransferableRow: Transferable {
    let rowIndex: String
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.rowIndex)
    }
}

private struct CSVTransferable: Transferable {
    var writeCSV: () throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            exportedContentType: .commaSeparatedText,
            exporting: { csv in
                let url = try csv.writeCSV()
                let file = SentTransferredFile(
                    url,
                    allowAccessingOriginalFile: false
                )
                return file
            }
        )
        /// Has to be set.
        /// Otherwise, the app will crash with the following when user presses on the save button in the file exporter dialog.
        /// ```bash
        /// *** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '-[NSFileWrapper setPreferredFilename:] *** preferredFilename cannot be empty.'
        /// terminating due to uncaught exception of type NSException
        /// ```
        /// setting `defaultFilename` on the `fileExporter` will NOT solve the problem
        .suggestedFileName("exported.csv")
    }
}

// MARK: - custom SortComparator
/// For columns created programmatically, it can take types like date, array, and etc.
/// However, for columns loaded from CSV, they seem to be always taking `Int`, `Double`, and `String` (even date strings will be string).
/// Technically speaking, for the current set up where the user will only be able to choose from `Int`, `Double`, and `String`,
/// and loaded CSV will also only result in those three types,
/// `Int`, `Double`, and `String` are all we need to handle here.
private struct AnyComparator: SortComparator {

    var order: SortOrder = .forward

    typealias Compared = Any?

    static func isComparable(_ type: Any.Type = Any.self) -> Bool {
        return type is Int.Type || type is String.Type || type is Double.Type
    }

    func compare(_ lhs: Any?, _ rhs: Any?)
        -> ComparisonResult
    {
        /// Int
        if let lhs = lhs as? Int?, let rhs = rhs as? Int? {
            return compareInt(lhs, rhs)
        }

        /// Double
        if let lhs = lhs as? Double?, let rhs = rhs as? Double? {
            return compareDouble(lhs, rhs)
        }

        /// String
        if let lhs = lhs as? String?, let rhs = rhs as? String? {
            return compareString(lhs, rhs)
        }

        /// UUID
        if let lhs = lhs as? UUID?, let rhs = rhs as? UUID? {
            return compareString(lhs?.uuidString, rhs?.uuidString)
        }

        /// Date
        if let lhs = lhs as? Date?, let rhs = rhs as? Date? {
            return compareDate(lhs, rhs)
        }

        /// Array
        if let lhs = lhs as? [Any]?, let rhs = rhs as? [Any]? {
            return compareArray(lhs, rhs)
        }

        guard let lhs, let rhs else {
            return compareNil(lhs == nil, rhs == nil)
        }

        /// Fall back to string
        return compareString(String(describing: lhs), String(describing: rhs))
    }

    private func compareNil(_ lhs: Bool, _ rhs: Bool) -> ComparisonResult {
        if lhs == rhs {
            return .orderedSame
        }
        if order == .forward {
            return lhs == true ? .orderedDescending : .orderedAscending
        } else {
            return lhs == true ? .orderedAscending : .orderedDescending
        }
    }

    private func compareInt(_ lhs: Int?, _ rhs: Int?)
        -> ComparisonResult
    {
        guard let lhs, let rhs else {
            return compareNil(lhs == nil, rhs == nil)
        }
        if order == .forward {
            return lhs > rhs ? .orderedDescending : .orderedAscending
        } else {
            return lhs > rhs ? .orderedAscending : .orderedDescending
        }
    }

    private func compareDouble(_ lhs: Double?, _ rhs: Double?)
        -> ComparisonResult
    {
        guard let lhs, let rhs else {
            return compareNil(lhs == nil, rhs == nil)
        }

        if order == .forward {
            return lhs > rhs ? .orderedDescending : .orderedAscending
        } else {
            return lhs > rhs ? .orderedAscending : .orderedDescending
        }
    }

    private func compareString(_ lhs: String?, _ rhs: String?)
        -> ComparisonResult
    {
        guard let lhs, let rhs else {
            return compareNil(lhs == nil, rhs == nil)
        }

        /// Enable numeric here to handle date string as well.
        return String.Comparator(
            options: [.caseInsensitive, .numeric],
            order: self.order
        )
        .compare(lhs, rhs)
    }

    private func compareDate(_ lhs: Date?, _ rhs: Date?)
        -> ComparisonResult
    {
        guard let lhs, let rhs else {
            return compareNil(lhs == nil, rhs == nil)
        }

        /// not using Date.compare as it does not take order into account nor have a parameter for the order
        if order == .forward {
            return lhs > rhs ? .orderedDescending : .orderedAscending
        } else {
            return lhs > rhs ? .orderedAscending : .orderedDescending
        }
    }

    private func compareArray(_ lhs: [Any]?, _ rhs: [Any]?)
        -> ComparisonResult
    {
        guard let lhs = lhs?.count, let rhs = rhs?.count else {
            return compareNil(lhs == nil, rhs == nil)
        }

        /// not using Date.compare as it does not take order into account nor have a parameter for the order
        if order == .forward {
            return lhs > rhs ? .orderedDescending : .orderedAscending
        } else {
            return lhs > rhs ? .orderedAscending : .orderedDescending
        }
    }

}

// MARK: - Views
struct TabularDataTableDemo: View {
    @State private var dataFrame: DataFrame?
    @State private var showImporter = false
    @State private var error: Error?

    @State private var importedFileURL: URL?
    private var importedFileName: String? {
        importedFileURL?.lastPathComponent
    }

    var body: some View {

        NavigationStack {
            Group {
                if let dataFrame {
                    TableView(dataFrame: dataFrame)
                        .navigationTitle(
                            importedFileName?.split(separator: ".").first
                                ?? "CSV"
                        )
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(
                                    action: {
                                        self.dataFrame = nil
                                        self.importedFileURL = nil
                                    },
                                    label: {
                                        Text("Close")
                                    }
                                )
                            }
                        }
                } else {
                    VStack(spacing: 16) {
                        VStack(spacing: 8) {
                            Button("Open") {
                                self.showImporter = true
                            }

                            if let error {
                                Text(
                                    "Error importing file: \(error.localizedDescription)"
                                )
                                .foregroundStyle(.red)
                                .task {
                                    try? await Task.sleep(for: .seconds(2))
                                    self.error = nil
                                }
                            }
                        }
                        Button("New", action: self.makeSampleDataFrame)
                    }
                    .navigationTitle("CSV Editor")
                    .fileImporter(
                        isPresented: $showImporter,
                        allowedContentTypes: [.commaSeparatedText]
                    ) { result in
                        switch result {
                        case .success(let url):
                            self.loadCSV(url)
                        case .failure(let failure):
                            self.error = failure
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func makeSampleDataFrame() {
        self.dataFrame = DataFrame(
            dictionaryLiteral: ("string", ["hello", "hey", "what's up?"]),
            ("Int", [1, 2, 3]),
            ("Double", [1.1, 1.2, 1.3]),
        )
    }

    private func loadCSV(_ url: URL) {
        let _ = url.startAccessingSecurityScopedResource()
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        do {
            self.importedFileURL = url
            self.dataFrame = try DataFrame(contentsOfCSVFile: url)
        } catch {
            self.error = error
        }
    }
}

private struct TableView: View {

    private struct InsertColumnParameter: Identifiable, Hashable {
        var id: UUID = UUID()
        var targetIndex: Int
    }

    @State var dataFrame: DataFrame
    var importedFileURL: URL?

    private static let order: SortOrder = .forward

    @State private var sortOrder: [KeyPathComparator<IdentifiableRow>] = [
        KeyPathComparator(\IdentifiableRow.id, order: Self.order)
    ]

    @State private var columnCustomization = TableColumnCustomization<
        IdentifiableRow
    >()

    @State private var rowSelection: IdentifiableRow.ID? = nil

    @State private var colSelection: IdentifiableColumn.ID? = nil

    private var rows: [IdentifiableRow] {
        Array(dataFrame.rows).map(IdentifiableRow.init)
    }

    private var sortedRows: [IdentifiableRow] {
        return rows.sorted(using: sortOrder)
    }

    private var columns: [IdentifiableColumn] {
        Array(dataFrame.columns).enumerated().map({
            IdentifiableColumn.init($0.element, index: $0.offset)
        })
    }

    private var headerRow: IdentifiableRow {
        IdentifiableRow(colNames: columns.map(\.name))
    }

    @State private var editColumn = false

    @State private var showExporter = false

    @State private var showColumnTypeSelection: InsertColumnParameter? = nil
    @State private var selectedColumnType: ValueType = .string

    @State private var error: Error?

    var body: some View {

        VStack(spacing: 16) {
            if let error {
                Text(
                    "Error importing file: \(error.localizedDescription)"
                )
                .foregroundStyle(.red)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    self.error = nil
                }
            }
            self.table
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(
                    action: {
                        showExporter = true
                    },
                    label: {
                        Text("Save")
                    }
                )
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(editColumn ? "Done" : "Edit Columns") {
                    /// have to set it nil once before setting to headerRow.id
                    /// otherwise, there will be 2 selected rows visual-wise. (even though selection is a singular binding)
                    self.rowSelection = nil
                    self.colSelection = nil

                    Task {
                        try? await Task.sleep(for: .milliseconds(1))
                        self.editColumn.toggle()
                        if editColumn {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                self.dataFrame = reorderedColumns()
                                self.columnCustomization = .init()
                                self.rowSelection = self.headerRow.id
                            }
                        }
                    }
                }
            }
        }
        .fileDialogDefaultDirectory(
            self.importedFileURL?.deletingLastPathComponent()
        )
        .fileExporter(
            isPresented: $showExporter,
            item: CSVTransferable(writeCSV: {
                return try self.saveCSV()
            }),
            defaultFilename: self.importedFileURL?.lastPathComponent
                ?? "export.csv"
        ) { result in
            if case .failure(let error) = result {
                self.error = error
            }
        }
        .sheet(item: $showColumnTypeSelection) { col in
            VStack(spacing: 16) {
                Picker("Column type", selection: $selectedColumnType) {
                    ForEach(ValueType.allCases) { type in
                        Text(type.rawValue.capitalized)
                            .tag(type)
                    }
                }

                Button("Confirm") {
                    self.insertCol(
                        at: col.targetIndex,
                        of: self.selectedColumnType
                    )
                    self.showColumnTypeSelection = nil
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .fixedSize()
            .padding()
        }
    }

    @ContentBuilder
    private var table: some View {
        Table(
            of: IdentifiableRow.self,
            selection: $rowSelection,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization,
            columns: {
                self.columnContent
            },
            rows: {
                self.rowContent
            }
        )
        .tableColumnHeaders(editColumn ? .hidden : .visible)
    }

    @TableRowBuilder<IdentifiableRow>
    private var rowContent: some TableRowContent<IdentifiableRow> {
        if editColumn {
            TableRow(headerRow)
            ForEach(sortedRows) { row in
                TableRow(row)
                    .selectionDisabled()
                    .contextMenu {
                        rowEditMenu(row.index)
                    }
            }

        } else {
            ForEach(sortedRows) { row in
                TableRow(row)
                    .draggable(TransferableRow(rowIndex: String(row.index)))
                    /// since we are using proxy representable, the type here has to be string instead of TransferableRow
                    .dropDestination(for: String.self) {
                        movedRows in
                        let movedIndices: [Int] = movedRows.compactMap {
                            Int($0)
                        }.sorted().reversed()

                        let destinationIndex = row.index

                        let toMove = self.rows.filter({
                            movedIndices.contains($0.index)
                        })

                        movedIndices.forEach {
                            dataFrame.removeRow(at: $0)
                        }

                        toMove.forEach {
                            dataFrame.insert(
                                row: $0.row,
                                at: destinationIndex
                            )
                        }
                    }
                    .contextMenu {
                        rowEditMenu(row.index)
                    }
            }
        }
    }

    @TableColumnBuilder<IdentifiableRow, KeyPathComparator<IdentifiableRow>>
    private var columnContent:
        some TableColumnContent<
            IdentifiableRow, KeyPathComparator<IdentifiableRow>
        >
    {
        TableColumn(Text(" ").font(.headline), value: \.index) { row in
            if row.index != IdentifiableRow.headerRowIndex {
                Text("\(row.index)")
            }
        }
        .width(36)
        /// this will disable **THIS** column from being dragged, however, it will NOT disable other column from being dragged ahead of this column which will eventually cause this item to be reordered.
        .disabledCustomizationBehavior(.reorder)
        .customizationID("index")

        TableColumnForEach(columns) { column in
            let columnName = column.name
            let colId = column.id
            let colIndex = column.index
            let column = column.col

            TableColumn(
                Text(columnName).font(.headline),
                /// Use the custom subscript for keyPath.
                /// The built in one using the position (column index) does not check whether if the index is out of bound
                /// which causes crash when inserting / deleting columns.
                /// Also, we cannot use `columnName` here for subscript neither as that will cause crash when renaming a column.
                value: \.row[colIndex, true],
                comparator: AnyComparator(
                    order: Self.order
                )
            ) { row in
                let rowIndex = row.index
                let isHeader =
                    rowIndex == IdentifiableRow.headerRowIndex
                let rowId = row.id
                let row = row.row
                /// Use the custom subscript for keyPath.
                /// The built in one does not check whether if the index is out of bound
                /// which causes crash when inserting / deleting columns.
                /// Also, we cannot use `columnName` here for subscript neither as that will cause crash when renaming a column.
                let value = row[colIndex, true]

                Group {
                    if editColumn {
                        if isHeader {
                            EditableContent(
                                text: String(describing: value ?? ""),
                                type: String.self,
                                update: {
                                    self.updateColumnName(
                                        $0,
                                        column: column,
                                    )
                                },
                                tableSelection: $rowSelection,
                                rowId: rowId,
                            )
                            .contextMenu {
                                colEditMenu(colIndex, name: columnName)
                            }
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    self.colSelection = colId
                                }
                            )
                        } else {
                            Text(String(describing: value ?? ""))
                        }
                    } else {
                        EditableContent(
                            text: String(describing: value ?? ""),
                            type: column.wrappedElementType,
                            update: {
                                self.updateCell(
                                    $0,
                                    columnIndex: colIndex,
                                    columnType: column.wrappedElementType,
                                    rowIndex: rowIndex
                                )
                            },
                            tableSelection: $rowSelection,
                            rowId: rowId
                        )
                    }
                }
                .font(isHeader ? .headline : .body)
                .padding(.vertical, isHeader ? 8 : 4)
                .padding(.horizontal, 2)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .leading
                )
                .background {
                    if self.colSelection == colId, editColumn {
                        Color.accentColor
                    }
                }
            }
            /// `colSelection` needs to be part of the id so that the column can get re-rendered when selected to have the background color reflected.
            .customizationID(
                makeColumnCustomizationID(name: columnName, id: colId)
            )
        }
    }

    func makeColumnCustomizationID(name: String, id: IdentifiableColumn.ID)
        -> String
    {
        /// no need to add in the id itself into the id as the name is guaranteed to be unique by tabular data
        /// Also, we want the customization id to be independent of id (derived from the index of the column) so that it can remain to be the same when reordering columns.
        return "\(name)_\(id == self.colSelection)"
    }

    func columnNameFromCustomizationID(_ customizationId: String) -> String? {
        var splits = customizationId.split(separator: "_")
        splits.removeLast()
        return splits.joined(separator: "_")
    }

    /// returning a new frame instead of updating the current one
    /// Because setting `self.dataFrame` with column customization will result in unwanted UI (changed columns will change to the new position, swap back to the original position, then change to the new position)
    func reorderedColumns() -> DataFrame {
        let currentFrame = DataFrame(columns: self.dataFrame.columns)
        let columnCustomizationIDs = self.columnCustomization.columnOrder
        guard !columnCustomizationIDs.isEmpty else {
            return currentFrame
        }
        let reorderedColumns: [IdentifiableColumn] =
            columnCustomizationIDs.map(
                columnNameFromCustomizationID
            ).compactMap({ $0 }).map({ name in
                self.columns.first(where: { $0.name == name })
            }).compactMap { $0 }

        guard reorderedColumns.count == self.columns.count else {
            return currentFrame
        }

        return DataFrame(columns: reorderedColumns.map(\.col))
    }

    private func saveCSV() throws -> URL {
        let dataFrame = self.reorderedColumns()
        let url = URL.temporaryDirectory.appending(
            path: "temp.csv"
        )
        /// https://developer.apple.com/documentation/tabulardata/dataframeprotocol/writecsv(to:options:)
        try dataFrame.writeCSV(to: url)
        return url
    }

    @ContentBuilder
    private func colEditMenu(_ index: Int, name: String) -> some View {
        Button("Add Column Before") {
            self.showColumnTypeSelection = .init(targetIndex: index)
        }
        Button("Add Column After") {
            self.showColumnTypeSelection = .init(targetIndex: index + 1)
        }
        Divider()
        Button("Duplicate Column") {
            self.duplicateCol(at: index)
        }
        Divider()
        Button("Delete Column") {
            deleteCol(name)
        }
    }

    @ContentBuilder
    private func rowEditMenu(_ index: Int) -> some View {
        Button("Add Row Above") {
            self.insertRow(at: index)
        }
        Button("Add Row Below") {
            self.insertRow(at: index + 1)
        }
        Divider()
        Button("Duplicate Row") {
            duplicateRow(at: index)
        }
        Divider()
        Button("Delete Row") {
            deleteRow(at: index)
        }
    }

    private func deleteRow(at index: Int) {
        guard index < self.dataFrame.rows.count else {
            return
        }
        self.dataFrame.removeRow(at: index)
    }

    private func insertRow(at index: Int) {
        var rowFrame = DataFrame(self.dataFrame.prefix(0))
        rowFrame.appendEmptyRow()
        self.dataFrame.insert(row: rowFrame.rows[0], at: index)
    }

    private func duplicateRow(at index: Int) {
        guard index < self.dataFrame.rows.count else {
            return
        }
        let row = self.dataFrame.rows[index]
        self.dataFrame.insert(row: row, at: index + 1)
    }

    private func duplicateCol(at index: Int) {
        guard index < self.dataFrame.columns.count else {
            return
        }
        var column = self.dataFrame.columns[index]
        column.name = resolveColumnName(column.name)
        self.dataFrame.insert(column: column, at: index + 1)
    }

    private func deleteCol(_ name: String) {
        guard self.dataFrame.containsColumn(name) else { return }
        self.dataFrame.removeColumn(name)
    }

    private func insertCol(at index: Int, of type: ValueType) {
        let columnName = resolveColumnName("new")

        /// we will use the rowCount for capacity but it actually doesn't matter.
        /// Even if we just set capacity to 0 or something larger than rowCount,
        /// no additional rows will be created, and the new column will still be all filled with nil.
        let rowCount = dataFrame.rows.count
        let column: AnyColumn
        switch type {
        case .string:
            column = Column<String>(name: columnName, capacity: rowCount)
                .eraseToAnyColumn()
        case .int:
            column = Column<Int>(name: columnName, capacity: rowCount)
                .eraseToAnyColumn()
        case .double:
            column = Column<Double>(name: columnName, capacity: rowCount)
                .eraseToAnyColumn()
        }

        self.dataFrame.insert(column: column, at: index)
    }

    private func updateCell(
        _ value: Any?,
        columnIndex: Int,
        columnType: any Any.Type,
        rowIndex: Int
    ) {
        guard columnIndex < self.dataFrame.columns.count,
            rowIndex < self.dataFrame.rows.count
        else {
            return
        }
        /// should be the same type, but an additional defensive check as different type will cause crashes
        /// Since we are not allow editing of other types, we are only checking int, string, and double
        if columnType is Int.Type, !(value is Int?) { return }
        if columnType is String.Type, !(value is String?) { return }
        if columnType is Double.Type, !(value is Double?) { return }

        dataFrame[column: columnIndex][rowIndex] = value
    }

    private func updateColumnName(
        _ value: Any?,
        column: AnyColumn,
    ) {
        let value: String =
            if let value = value as? String {
                value
            } else { "" }
        let newName = resolveColumnName(value)
        dataFrame.renameColumn(column.name, to: newName)
    }

    /// make sure the new column name does not exist in the current frame. otherwise the app will crash.
    private func resolveColumnName(_ base: String) -> String {
        var newName = base
        var loop = 1
        while self.dataFrame.containsColumn(newName) {
            newName = base + "_" + String(loop)
            if !self.columns.map(\.name).contains(newName) {
                break
            }
            loop += 1
        }

        return newName
    }
}

private struct EditableContent: View {

    init(
        text: String?,
        type: any Any.Type,
        update: @escaping (Any?) -> Void,
        tableSelection: Binding<IdentifiableRow.ID?>,
        rowId: IdentifiableRow.ID,
    ) {
        self.valueType = ValueType(type)
        self._tableSelection = tableSelection
        self.previousValue = text ?? ""
        self.update = update
        self.rowId = rowId
        if let text {
            self._text = State(initialValue: text)
            self._int = State(initialValue: Int(text) ?? 0)
            self._double = State(initialValue: Double(text) ?? 0.0)
        } else {
            self._text = State(initialValue: "")
            self._int = State(initialValue: nil)
            self._double = State(initialValue: nil)
        }
    }

    var update: (_ newValue: Any?) -> Void
    @Binding var tableSelection: IdentifiableRow.ID?
    var rowId: IdentifiableRow.ID

    private var previousValue: String?

    private var valueType: ValueType?
    @State private var text: String
    @State private var int: Int?
    @State private var double: Double?

    @State private var textSelection: TextSelection?
    @FocusState private var focused

    var body: some View {
        Text(text)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.clear)
            .overlay(content: {
                if let valueType {
                    self.textField(valueType)
                }
            })
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            /// required instead of using `onChange(of: self.tableSelection) { self.focused = false }` to reset
            /// so that when focused, and user tapped another row, the row can indeed be highlighted (otherwise, it will be selected, but grayed, instead of taking the highlighted link color.)
            .simultaneousGesture(
                TapGesture()
                    .onEnded({
                        focused = false
                        self.tableSelection = rowId
                    }),
                isEnabled: !focused
            )
            .onChange(of: focused) {
                guard !focused else { return }
                self.runUpdate()
            }

    }

    @ContentBuilder
    private func textField(_ type: ValueType) -> some View {
        Group {
            switch type {
            case .double:
                TextField("", value: $double, format: .number)
            case .int:
                TextField("", value: $int, format: .number)
            case .string:
                TextField("", text: $text, selection: $textSelection)
            }
        }
        .focused($focused)
        .onExitCommand {
            self.undoChanges()
            focused = false
        }
        .onSubmit {
            focused = false
        }
        .frame(maxWidth: .infinity)
        .overlay {
            Color.clear
                .frame(
                    minWidth: 60,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .contentShape(Rectangle())
                .allowsHitTesting(!focused)
                .gesture(
                    TapGesture()
                        .onEnded({
                            guard tableSelection == rowId else {
                                return
                            }
                            self.focused = true
                        }),
                    isEnabled: tableSelection == rowId
                        && !self.focused
                )

        }
    }

    private func runUpdate() {
        guard let valueType else { return }
        switch valueType {
        case .string:
            self.update(text)
        case .int:
            self.update(int)
        case .double:
            self.update(double)
        }
    }

    private func undoChanges() {
        guard let valueType else { return }
        switch valueType {
        case .string:
            self.text = previousValue ?? ""
        case .int:
            if let previousValue {
                self.int = Int(previousValue)
            } else {
                self.int = nil
            }
        case .double:
            if let previousValue {
                self.double = Double(previousValue)
            } else {
                self.double = nil
            }
        }
    }
}
