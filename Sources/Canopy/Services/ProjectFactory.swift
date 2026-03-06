import Foundation

enum ProjectFactory {
    static func newProject() -> CanopyProject {
        let bpm = Double(Int.random(in: 60...170))
        let root = PitchClass.allCases.randomElement()!
        let mode = ScaleMode.allCases.filter { $0 != .chromatic }.randomElement()!
        let key = MusicalKey(root: root, mode: mode)

        let seedNode = Node(
            name: "Seed",
            type: .seed,
            key: key,
            sequence: NoteSequence(lengthInBeats: 4),
            patch: SoundPatch(
                name: "Sine Seed",
                soundType: .oscillator(OscillatorConfig(waveform: .sine))
            ),
            position: NodePosition(x: 0, y: 0)
        )

        let tree = NodeTree(
            name: "Tree 1",
            rootNode: seedNode
        )

        let arrangement = Arrangement(
            name: "Main",
            treeIDs: [tree.id]
        )

        return CanopyProject(
            name: "Untitled",
            bpm: bpm,
            globalKey: key,
            trees: [tree],
            arrangements: [arrangement]
        )
    }
}
