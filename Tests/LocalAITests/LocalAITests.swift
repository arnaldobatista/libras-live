import Foundation
import Testing
@testable import LocalAI

@Suite struct OllamaLibraryTests {
    static let searchHTML = #"""
    <ul role="list" class="grid grid-cols-1">
    <li  class="flex items-baseline border-b border-neutral-200 py-6">
      <a href="/library/gemma4" class="group w-full">
        <div class="flex flex-col mb-1" title="gemma4">
          <h2 class="truncate text-xl font-medium"><span >gemma4</span></h2>
          <p class="max-w-lg break-words text-neutral-800 text-md">Gemma 4 models are designed to deliver frontier-level performance &amp; more.</p>
        </div>
        <div class="flex flex-col">
          <div class="flex flex-wrap space-x-2">
            <span  class="inline-flex my-1 items-center rounded-md bg-indigo-50 px-2 text-indigo-600 sm:text-[13px]">vision</span>
            <span  class="inline-flex my-1 items-center rounded-md bg-indigo-50 px-2 text-indigo-600 sm:text-[13px]">thinking</span>
            <span class="inline-flex my-1 items-center rounded-md bg-cyan-50 px-2 text-cyan-500 sm:text-[13px]">cloud</span>
            <span  class="inline-flex my-1 items-center rounded-md bg-[#ddf4ff] px-2 text-blue-600 sm:text-[13px]">e2b</span>
            <span  class="inline-flex my-1 items-center rounded-md bg-[#ddf4ff] px-2 text-blue-600 sm:text-[13px]">12b</span>
          </div>
          <p class="my-1 flex space-x-5 text-[13px] font-medium text-neutral-500">
              <span class="flex items-center">
                <svg class="mr-1.5"></svg>
                <span >25M</span>
                <span class="hidden sm:flex">&nbsp;Pulls</span>
              </span>
              <span class="flex items-center" title="Aug 31, 2026 8:52 PM UTC">
                <span class="hidden sm:flex">Updated&nbsp;</span>
                <span >2 weeks ago</span>
              </span>
          </p>
        </div>
      </a>
    </li>
    <li  class="flex items-baseline border-b border-neutral-200 py-6">
      <a href="/library/glm-5.3" class="group w-full">
        <p class="max-w-lg break-words text-neutral-800 text-md">Cloud flagship.</p>
        <span class="inline-flex my-1 items-center rounded-md bg-cyan-50 px-2">cloud</span>
      </a>
    </li>
    <li class="menu">Sem link</li>
    </ul>
    """#

    static let tagsHTML = #"""
    <a href="/library/gemma4:e4b" class="md:hidden flex flex-col space-y-[6px] group">
      <div class="flex items-center font-medium"><span class="group-hover:underline">gemma4:e4b</span></div>
      <div class="flex flex-col text-neutral-500 text-[13px]">
        <span>
          <span class="font-mono">
            c6eb396dbd59</span> • 9.6GB • 128K context window  •
          <span class="hidden sm:inline">
            Text, Image input •
            5 months ago
          </span>
        </span>
      </div>
    </a>
    <a href="/library/gemma4:e2b-mlx" class="md:hidden flex flex-col">
      <span class="font-mono">abc</span> • 7.5GB • 128K context window  •
      <span class="hidden sm:inline">Text input • 1 month ago</span>
    </a>
    <a href="/library/gemma4:e4b" class="group-hover:underline">gemma4:e4b</a>
    """#

    @Test func parsesSearchResults() {
        let models = OllamaLibrary.parseSearch(Self.searchHTML)
        #expect(models.map(\.name) == ["gemma4", "glm-5.3"])
        let gemma = models[0]
        #expect(gemma.summary == "Gemma 4 models are designed to deliver frontier-level performance & more.")
        #expect(gemma.capabilities == ["vision", "thinking"])
        #expect(gemma.sizes == ["e2b", "12b"])
        #expect(!gemma.cloudOnly)
        #expect(gemma.pulls == "25M")
        #expect(gemma.updated == "2 weeks ago")
        #expect(models[1].cloudOnly)
    }

    @Test func parsesTagsAndFlagsUnsupported() {
        let tags = OllamaLibrary.parseTags(Self.tagsHTML)
        #expect(tags.map(\.name) == ["gemma4:e4b", "gemma4:e2b-mlx"])
        #expect(tags[0].size == "9.6GB")
        #expect(tags[0].bytes == 9_600_000_000)
        #expect(tags[0].context == "128K")
        #expect(tags[0].inputs == "Text, Image")
        #expect(tags[0].runsHere)
        #expect(!tags[1].runsHere)
    }
}

@Suite struct OllamaClientDecodingTests {
    @Test func decodesInstalledModelsWithNanosecondDates() throws {
        let json = #"""
        {"models":[{"name":"qwen3.5:0.8b","model":"qwen3.5:0.8b","modified_at":"2026-09-15T09:49:53.436950674-03:00","size":1036046583,
        "digest":"f381","details":{"format":"gguf","family":"qwen35","parameter_size":"873.44M","quantization_level":"Q8_0"},
        "capabilities":["vision","completion","tools","thinking"]}]}
        """#
        struct Response: Decodable { let models: [InstalledModel] }
        let models = try OllamaClient.decoder.decode(Response.self, from: Data(json.utf8)).models
        #expect(models.first?.details?.parameterSize == "873.44M")
        #expect(models.first?.capabilities?.contains("thinking") == true)
        let date = try #require(models.first?.modifiedAt)
        #expect(abs(date.timeIntervalSince1970 - 1_789_476_593.437) < 0.01)
    }

    @Test func decodesPullProgress() throws {
        let event = try OllamaClient.decoder.decode(PullEvent.self, from: Data(#"{"status":"pulling afb7","digest":"sha256:afb7","total":1036034688,"completed":67905984}"#.utf8))
        #expect(event.total == 1_036_034_688)
        #expect(event.completed == 67_905_984)
        let partial = try OllamaClient.decoder.decode(PullEvent.self, from: Data(#"{"status":"pulling afb7","digest":"sha256:afb7","total":1036034688}"#.utf8))
        #expect(partial.completed == nil)
    }
}

@Suite struct ModelCatalogTests {
    @Test func fitsBySpareMemory() {
        let macbook = MachineInfo(modelName: "MacBook Pro", chip: "Apple M1 Pro", memoryGB: 16)
        #expect(ModelCatalog.fit(memoryGB: 2.9, on: macbook) == .great)
        #expect(ModelCatalog.fit(memoryGB: 6.5, on: macbook) == .tight)
        #expect(ModelCatalog.fit(memoryGB: 10, on: macbook) == .tooBig)
        let air = MachineInfo(modelName: "MacBook Air", chip: "Apple M2", memoryGB: 8)
        #expect(ModelCatalog.fit(memoryGB: 2.9, on: air) == .tooBig)
    }

    @Test func comparesNamesWithLatestTag() {
        #expect(ModelCatalog.sameModel("llama3.2", "llama3.2:latest"))
        #expect(!ModelCatalog.sameModel("qwen3.5:4b", "qwen3.5:2b"))
        #expect(MachineInfo.friendlyName(forIdentifier: "MacBookPro18,3") == "MacBook Pro")
    }
}

@Suite struct DeadlineTests {
    @Test func returnsBeforeDeadline() async throws {
        let value = try await withDeadline(1) { 42 }
        #expect(value == 42)
    }

    @Test func throwsAfterDeadline() async {
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(0.05) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
    }
}
