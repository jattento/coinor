import Testing

@testable import Coinor

@Suite
struct RemoteRepositoryCandidateFilterTests {
    @Test
    func emptyQueryPreservesDiscoveryOrder() {
        let candidates = [
            candidate("Zulu", path: "/src/zulu"),
            candidate("Alpha", path: "/src/alpha"),
        ]

        #expect(
            RemoteRepositoryCandidateFilter.filtered(
                candidates,
                query: "  \n "
            ).map(\.path) == candidates.map(\.path)
        )
    }

    @Test
    func exactPrefixSubstringAndPathMatchesRankInThatOrder() {
        let candidates = [
            candidate("Backend", path: "/work/api/backend"),
            candidate("My API Tools", path: "/work/tools"),
            candidate("API Client", path: "/work/client"),
            candidate("API", path: "/work/exact"),
        ]

        #expect(
            RemoteRepositoryCandidateFilter.filtered(
                candidates,
                query: "api"
            ).map(\.path) == [
                "/work/exact",
                "/work/client",
                "/work/tools",
                "/work/api/backend",
            ]
        )
    }

    @Test
    func tokenAndSubsequenceMatchesRemainFuzzy() {
        let candidates = [
            candidate("Coinor Remote Picker", path: "/work/coinor-picker"),
            candidate("Remote Project Filter", path: "/work/filter"),
            candidate("Unrelated", path: "/work/other"),
        ]

        #expect(
            RemoteRepositoryCandidateFilter.filtered(
                candidates,
                query: "remote pick"
            ).map(\.path) == ["/work/coinor-picker"]
        )
        #expect(
            RemoteRepositoryCandidateFilter.filtered(
                candidates,
                query: "rpf"
            ).map(\.path) == ["/work/filter"]
        )
    }

    @Test
    func filteringIsCaseAndDiacriticInsensitive() {
        let candidates = [
            candidate("Résumé Tools", path: "/work/resume-tools"),
        ]

        #expect(
            RemoteRepositoryCandidateFilter.filtered(
                candidates,
                query: "RESUME"
            ).map(\.path) == ["/work/resume-tools"]
        )
    }

    private func candidate(
        _ name: String,
        path: String
    ) -> RemoteRepositoryCandidate {
        RemoteRepositoryCandidate(path: path, name: name)
    }
}
