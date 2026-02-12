import Foundation

enum ProjectFactory {
    static func newProject() -> CanopyProject {
        let seedNode = Node(
            name: "Seed",
            type: .seed,
            key: MusicalKey(root: .C, mode: .minor),
            sequence: NoteSequence(lengthInBeats: 16),
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
            bpm: 120,
            globalKey: MusicalKey(root: .C, mode: .minor),
            trees: [tree],
            arrangements: [arrangement]
        )
    }
}
