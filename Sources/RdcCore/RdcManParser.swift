import Foundation

public struct RdcManParser: Sendable {
    public init() {}

    public func parse(fileAt url: URL) throws -> RdcManDocument {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    public func parse(data: Data) throws -> RdcManDocument {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder

        guard parser.parse(), let root = builder.root else {
            throw RdcManParserError.invalidXML(parser.parserError?.localizedDescription)
        }

        guard root.name == "RDCMan" else {
            throw RdcManParserError.unexpectedRoot(root.name)
        }

        guard let fileNode = root.firstChild(named: "file") else {
            throw RdcManParserError.missingFileNode
        }

        return RdcManDocument(
            programVersion: root.attributes["programVersion"] ?? "",
            schemaVersion: root.attributes["schemaVersion"] ?? "",
            root: parseGroupLikeNode(fileNode)
        )
    }

    private func parseGroupLikeNode(_ node: XMLTreeNode) -> RdcGroup {
        let properties = node.firstChild(named: "properties")
        return RdcGroup(
            name: properties?.textForFirstChild(named: "name") ?? "",
            isExpanded: properties?.textForFirstChild(named: "expanded").flatMap(parseBool),
            logonCredentials: parseCredentials(node.firstChild(named: "logonCredentials")),
            groups: node.children(named: "group").map(parseGroupLikeNode),
            servers: node.children(named: "server").map(parseServer)
        )
    }

    private func parseServer(_ node: XMLTreeNode) -> RdcServer {
        let properties = node.firstChild(named: "properties")
        let address = properties?.textForFirstChild(named: "name") ?? ""
        return RdcServer(
            displayName: properties?.textForFirstChild(named: "displayName") ?? address,
            address: RdcServerAddress(address),
            logonCredentials: parseCredentials(node.firstChild(named: "logonCredentials"))
        )
    }

    private func parseCredentials(_ node: XMLTreeNode?) -> RdcLogonCredentials? {
        guard let node else {
            return nil
        }

        let passwordText = node.textForFirstChild(named: "password")
        return RdcLogonCredentials(
            inheritance: RdcInheritance(rawValue: node.attributes["inherit"]),
            profileName: node.textForFirstChild(named: "profileName"),
            userName: node.textForFirstChild(named: "userName"),
            domain: node.textForFirstChild(named: "domain"),
            password: passwordText.map(RdcPassword.windowsDPAPIEncrypted) ?? .none
        )
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }
}

public enum RdcManParserError: Error, Equatable {
    case invalidXML(String?)
    case unexpectedRoot(String)
    case missingFileNode
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLTreeNode?
    private var stack: [XMLTreeNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLTreeNode(name: elementName, attributes: attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
        if root == nil {
            root = node
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}

private final class XMLTreeNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLTreeNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func firstChild(named name: String) -> XMLTreeNode? {
        children.first { $0.name == name }
    }

    func children(named name: String) -> [XMLTreeNode] {
        children.filter { $0.name == name }
    }

    func textForFirstChild(named name: String) -> String? {
        firstChild(named: name)?.trimmedText
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
