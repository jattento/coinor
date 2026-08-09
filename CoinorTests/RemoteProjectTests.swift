import Foundation
import Testing

@testable import Coinor

@Suite
struct ProjectIdentityRemoteTests {
    @Test
    func bareAbsolutePathRemainsBackwardCompatibleAndLocal() {
        let identity = ProjectIdentity(rawValue: "/var/tmp/coinor/../project")
        let expected = URL(
            fileURLWithPath: "/var/tmp/coinor/../project",
            isDirectory: true
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path

        #expect(identity.rawValue == expected)
        #expect(identity.path == expected)
        #expect(identity.target == .local)
    }

    @Test
    func remoteIdentityQualifiesAndRoundTripsThePath() throws {
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
        let identity = ProjectIdentity(
            target: .remote(alias),
            commonDirectory: URL(
                fileURLWithPath: "/srv/projects/coinor",
                isDirectory: true
            )
        )

        #expect(identity.rawValue == "studio-mac:/srv/projects/coinor")
        #expect(identity.path == "/srv/projects/coinor")
        #expect(identity.target == .remote(alias))
        #expect(ProjectIdentity(rawValue: identity.rawValue) == identity)
    }

    @Test
    func remotePathsAreNeverResolvedAgainstTheLocalFileSystem() throws {
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
        let remote = ProjectIdentity(
            target: .remote(alias),
            commonDirectory: URL(
                fileURLWithPath: "/tmp/x",
                isDirectory: true
            )
        )
        let local = ProjectIdentity(rawValue: "/tmp/x")

        #expect(remote.rawValue == "studio-mac:/tmp/x")
        #expect(remote.path == "/tmp/x")
        #expect(!remote.path.hasPrefix("/private/tmp"))
        #expect(
            local.path
                == URL(fileURLWithPath: "/tmp/x", isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
        )
    }

    @Test
    func remotePathNormalizationCollapsesRepeatedAndDotComponents() throws {
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
        let identity = ProjectIdentity(
            rawValue: "studio-mac:/srv//projects/./coinor"
        )

        #expect(identity.rawValue == "studio-mac:/srv/projects/coinor")
        #expect(identity.path == "/srv/projects/coinor")
        #expect(identity.target == .remote(alias))
    }

    @Test
    func absoluteLocalPathContainingAColonIsNotAHostIdentity() {
        let identity = ProjectIdentity(
            rawValue: "/srv/projects/project:archive"
        )

        #expect(identity.target == .local)
        #expect(identity.path.hasSuffix("/project:archive"))
    }
}

@Suite
struct RemoteProjectDiscoveryTests {
    @Test
    func directoryEntriesParseTabSeparatedRepositoryMarkers() throws {
        let runner = FakeRemoteCommandRunner(
            results: [
                RemoteCommandResult(
                    standardOutput: "repo\tAlpha\ndir\tBeta\ninvalid\n",
                    standardError: "",
                    terminationStatus: 0
                ),
            ]
        )
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
        let discovery = RemoteProjectDiscovery(runner: runner, alias: alias)

        let entries = try discovery.directoryEntries(at: "/srv/projects/")

        #expect(
            entries
                == [
                    RemoteDirectoryEntry(
                        path: "/srv/projects/Alpha",
                        name: "Alpha",
                        isRepository: true
                    ),
                    RemoteDirectoryEntry(
                        path: "/srv/projects/Beta",
                        name: "Beta",
                        isRepository: false
                    ),
                ]
        )
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].remoteCommand.contains("cd '/srv/projects/'"))
    }

    @Test
    func candidatesStripGitSuffixesAndDeduplicateKnownAndScannedRoots() throws {
        let runner = FakeRemoteCommandRunner(
            results: [
                RemoteCommandResult(
                    standardOutput: """
                    /scan/Beta/.git
                    /known/Alpha/.git
                    /scan/Beta/.git
                    /scan/Gamma/.git
                    not-a-repository
                    """,
                    standardError: "",
                    terminationStatus: 0
                ),
            ]
        )
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
        let discovery = RemoteProjectDiscovery(runner: runner, alias: alias)

        let candidates = try discovery.candidates(
            knownGitRoots: [
                "/known/Alpha/.git",
                "/known/Alpha",
                "/known/Zeta/",
            ],
            searchRoots: ["/scan root"],
            maximumDepth: 2
        )

        #expect(
            candidates
                == [
                    RemoteRepositoryCandidate(
                        path: "/known/Alpha",
                        name: "Alpha"
                    ),
                    RemoteRepositoryCandidate(
                        path: "/scan/Beta",
                        name: "Beta"
                    ),
                    RemoteRepositoryCandidate(
                        path: "/scan/Gamma",
                        name: "Gamma"
                    ),
                    RemoteRepositoryCandidate(
                        path: "/known/Zeta",
                        name: "Zeta"
                    ),
                ]
        )
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].remoteCommand.contains("'/scan root'"))
        #expect(runner.calls[0].remoteCommand.contains("-maxdepth 2"))
    }

    @Test
    func failedScanStillReturnsNormalizedKnownRoots() throws {
        let runner = FakeRemoteCommandRunner(
            results: [
                RemoteCommandResult(
                    standardOutput: "",
                    standardError: "find failed",
                    terminationStatus: 1
                ),
            ]
        )
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
        let discovery = RemoteProjectDiscovery(runner: runner, alias: alias)

        let candidates = try discovery.candidates(
            knownGitRoots: [
                "/known/Alpha/.git",
                "/known/Alpha/",
                "/known/Beta",
            ]
        )

        #expect(
            candidates
                == [
                    RemoteRepositoryCandidate(
                        path: "/known/Alpha",
                        name: "Alpha"
                    ),
                    RemoteRepositoryCandidate(
                        path: "/known/Beta",
                        name: "Beta"
                    ),
                ]
        )
    }
}

@Suite
struct SSHGitCommandRunnerTests {
    @Test
    func composesQuotedRemoteGitCommandWithoutLaunchingSSH() throws {
        let runner = FakeRemoteCommandRunner(
            results: [
                RemoteCommandResult(
                    standardOutput: " M file.swift\n",
                    standardError: "warning\n",
                    terminationStatus: 7
                ),
            ]
        )
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
        let git = SSHGitCommandRunner(runner: runner, alias: alias)

        let result = try git.run(
            arguments: ["status", "--short"],
            workingDirectory: URL(
                fileURLWithPath: "/srv/Project With Space",
                isDirectory: true
            )
        )

        #expect(
            runner.calls.map(\.remoteCommand)
                == [
                    "cd '/srv/Project With Space' && exec env "
                        + "'GIT_TERMINAL_PROMPT=0' 'LANG=C' 'LC_ALL=C' "
                        + "'git' 'status' '--short'",
                ]
        )
        #expect(
            result
                == GitCommandResult(
                    standardOutput: " M file.swift\n",
                    standardError: "warning\n",
                    terminationStatus: 7
                )
        )
    }
}

private final class FakeRemoteCommandRunner:
    RemoteCommandRunning,
    @unchecked Sendable
{
    struct Call: Equatable {
        let remoteCommand: String
        let timeout: Duration
    }

    private var results: [RemoteCommandResult]
    private(set) var calls: [Call] = []

    init(results: [RemoteCommandResult]) {
        self.results = results
    }

    func run(
        remoteCommand: String,
        timeout: Duration
    ) throws -> RemoteCommandResult {
        calls.append(Call(remoteCommand: remoteCommand, timeout: timeout))
        guard !results.isEmpty else {
            preconditionFailure("FakeRemoteCommandRunner exhausted")
        }
        return results.removeFirst()
    }
}

@Suite
struct RemoteProjectVisibilityTests {
    private func summary(_ id: String, project: String) -> SessionSummary {
        SessionSummary(id: id, projectID: project, title: id)
    }

    @Test
    func hidingRemoteProjectsIsPresentationOnly() {
        var metadata = MetadataDocument.empty
        metadata.registerRemoteHost(RemoteHostAlias(rawValue: "studio")!)
        metadata.setRemoteProjectsHidden(true)

        // Hiding must not unregister the computer or archive anything.
        #expect(metadata.remoteHostAliases.count == 1)
        #expect(metadata.remoteProjectsHidden)
        #expect(!metadata.isProjectArchived("studio:/Users/other/repo"))
    }

    @Test
    func aHiddenCatalogKeepsOnlyLocalProjects() {
        let sessions = [
            summary("local-1", project: "/Users/me/repo"),
            summary("remote-1", project: "studio:/Users/other/repo"),
        ]
        var metadata = MetadataDocument.empty
        metadata.registerProject(
            "studio:/Users/other/manual",
            checkoutPath: "/Users/other/manual"
        )

        let visible = sessions.filter {
            !ProjectIdentity(rawValue: $0.projectID).target.isRemote
        }
        var hiddenMetadata = metadata
        hiddenMetadata.projects = metadata.projects.filter {
            !ProjectIdentity(rawValue: $0.key).target.isRemote
        }
        let catalog = SessionCatalog.build(
            sessions: visible,
            metadata: hiddenMetadata
        )

        #expect(catalog.projects.count == 1)
        #expect(catalog.projects.first?.projectID == "/Users/me/repo")
    }
}
