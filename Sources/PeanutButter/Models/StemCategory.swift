import Foundation

/// Canonical stem categories for MultiTracks Playback ordering
public enum StemCategory: Int, CaseIterable, Comparable, Sendable {
    case click = 1
    case guide = 2
    case drums = 3
    case percussion = 4
    case loops = 5
    case fx = 6
    case bass = 7
    case synthBass = 8
    case acousticGuitars = 9
    case electricGuitars = 10
    case piano = 11
    case organs = 12
    case keys = 13
    case arps = 14
    case synths = 15
    case orchestral = 16
    case vocals = 17
    case other = 18

    public static func < (lhs: StemCategory, rhs: StemCategory) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
    
    public var displayName: String {
        switch self {
        case .click: return "Click"
        case .guide: return "Guide"
        case .drums: return "Drums"
        case .percussion: return "Percussion"
        case .loops: return "Loops"
        case .fx: return "FX"
        case .bass: return "Bass"
        case .synthBass: return "Synth Bass"
        case .acousticGuitars: return "Acoustic Guitars"
        case .electricGuitars: return "Electric Guitars"
        case .piano: return "Piano"
        case .organs: return "Organs"
        case .keys: return "Keys"
        case .arps: return "Arps"
        case .synths: return "Synths"
        case .orchestral: return "Orchestral"
        case .vocals: return "Vocals"
        case .other: return "Other"
        }
    }
    
    /// Classifies an audio stem track based on its file/track name and optional explicit role
    public static func category(for trackName: String, role: TrackRole? = nil) -> StemCategory {
        if role == .click { return .click }
        if role == .guide { return .guide }
        
        let name = trackName.lowercased()
        
        // 1. Click Track (Track 1)
        if name.contains("click") || name.contains("metronome") || name == "metro" {
            return .click
        }
        
        // 2. Guide / Cue Track (Track 2)
        if name.contains("guide") || name.contains("cue") || name.contains("cues") ||
           name.contains("director") || name.contains("callout") || name.contains("slate") {
            return .guide
        }
        
        // 8. Synth Bass (Checked before generic Bass & Synths)
        if name.contains("synth bass") || name.contains("syn bass") || name.contains("synthbass") ||
           name.contains("sub bass") || name.contains("subbass") || name.contains("moog bass") ||
           name.contains("bass synth") || name.contains("808") || (name.contains("bass") && (name.contains("synth") || name.contains("sub"))) {
            return .synthBass
        }
        
        // 7. Bass (Electric, Acoustic, Upright, Bass Guitar)
        if name.contains("bass") {
            return .bass
        }
        
        // 9. Acoustic Guitars (Checked before generic Guitars, matches AG, AG1, AG2, etc.)
        if name.contains("acoustic guitar") || name.contains("ac guitar") || name.contains("ac gtr") ||
           name.contains("acoustic") || name.contains("acoust") || name.contains("nylon") ||
           name.contains("12 string") || name.contains("12-string") ||
           name.range(of: #"(^|[\s\-_.\(\[])(ag|acg)(\d*)([\s\-_.\)\]]|$)"#, options: .regularExpression) != nil {
            return .acousticGuitars
        }
        
        // 10. Electric Guitars (matches EG, EG1, EG2, etc. and generic Guitars)
        if name.contains("electric guitar") || name.contains("elec guitar") ||
           name.contains("lead guitar") || name.contains("rhythm guitar") || name.contains("gtr") ||
           name.contains("guitar") || name.contains("overdrive") || name.contains("dist gtr") ||
           name.contains("tele") || name.contains("strat") ||
           name.range(of: #"(^|[\s\-_.\(\[])(eg|elg)(\d*)([\s\-_.\)\]]|$)"#, options: .regularExpression) != nil {
            return .electricGuitars
        }
        
        // 3. Drums
        if name.contains("drum") || name.contains("snare") || name.contains("kick") ||
           name.contains("hihat") || name.contains("hi-hat") || name.contains("hat") ||
           name.contains("tom") || name.contains("overhead") || name.contains("cymbal") ||
           name.contains("ride") || name.contains("crash") || name.contains("kit") {
            return .drums
        }
        
        // 4. Percussion
        if name.contains("perc") || name.contains("percussion") || name.contains("shaker") ||
           name.contains("tambourine") || name.contains("tamb") || name.contains("conga") ||
           name.contains("bongo") || name.contains("clap") || name.contains("snap") ||
           name.contains("timbale") || name.contains("cowbell") || name.contains("cajon") {
            return .percussion
        }
        
        // 5. Loops
        if name.contains("loop") || name.contains("loops") || name.contains("beat") || name.contains("groove") {
            return .loops
        }
        
        // 6. FX (Sound Effects, Transitions)
        if name.contains("fx") || name.contains("sfx") || name.contains("sweep") ||
           name.contains("riser") || name.contains("downlifter") || name.contains("impact") ||
           name.contains("sub drop") || name.contains("white noise") || name.contains("laser") ||
           name.contains("transition") {
            return .fx
        }
        
        // 11. Piano (Acoustic & Electric Pianos)
        if name.contains("piano") || name.contains("grand") || name.contains("rhodes") ||
           name.contains("wurli") || name.contains("wurlitzer") || name.contains("e-piano") ||
           name.contains("ep ") || name == "ep" || name.contains("upright p") {
            return .piano
        }
        
        // 12. Organs
        if name.contains("organ") || name.contains("b3") || name.contains("hammond") ||
           name.contains("leslie") || name.contains("vox organ") {
            return .organs
        }
        
        // 14. Arps (Checked before generic Keys & Synths)
        if name.contains("arp") || name.contains("arpeggio") || name.contains("arpeggiator") {
            return .arps
        }
        
        // 13. Keys
        if name.contains("key") || name.contains("keyboard") || name.contains("clav") ||
           name.contains("celeste") || name.contains("mellotron") || name.contains("harpsichord") {
            return .keys
        }
        
        // 15. Synths (and Pads)
        if name.contains("synth") || name.contains("pad") || name.contains("pluck") ||
           name.contains("lead synth") || name.contains("poly") || name.contains("syn") {
            return .synths
        }
        
        // 16. Orchestral (Strings, Brass, Winds, Horns, Saxophones)
        if name.contains("string") || name.contains("violin") || name.contains("viola") ||
           name.contains("cello") || name.contains("brass") || name.contains("horn") ||
           name.contains("trumpet") || name.contains("trombone") || name.contains("tuba") ||
           name.contains("cornet") || name.contains("flugelhorn") ||
           name.contains("saxophone") || name.range(of: #"\bsax\b"#, options: .regularExpression) != nil ||
           name.contains("woodwind") || name.contains("wind") || name.contains("flute") ||
           name.contains("clarinet") || name.contains("oboe") || name.contains("bassoon") ||
           name.contains("piccolo") || name.contains("orchestra") || name.contains("orchestral") {
            return .orchestral
        }
        
        // 17. Vocals (Lead, BGVs, Harmonies, Adlibs, Choir)
        if name.contains("vocal") || name.contains("vox") || name.contains("bgv") ||
           name.contains("choir") || name.contains("harmony") || name.contains("lead vox") ||
           name.contains("lead voc") || name.contains("adlib") || name.contains("ad lib") ||
           name.contains("tenor") || name.contains("alto") || name.contains("soprano") {
            return .vocals
        }
        
        return .other
    }

    // MARK: - MultiTracks Playback Canonical Track Order & Abbreviations

    /// Canonical track order (`ZORDER`) and display abbreviations (`ZABBREVIATION`) from Playback's `ZMETADATATRACK`.
    private static let playbackTrackTable: [String: (order: Int, abbr: String)] = [
        "click track": (1, "Click"),
        "click": (1, "Click"),
        "pad": (2, "Pad"),
        "subclick accent": (3, "Accent"),
        "subclick quarter": (4, "1/4"),
        "subclick 8th": (5, "1/8"),
        "subclick 16th": (6, "1/16"),
        "md": (7, "MD"),
        "cowbell": (8, "Cowbell"),
        "md custom": (9, "MD Custom"),
        "guide (non-dynamic)": (10, "Guide C"),
        "md my voice": (11, "My Voice"),
        "guide (dynamic)": (12, "Guide"),
        "guide": (12, "Guide"),
        "sections": (13, "Sections"),
        "name your track": (14, "NYT"),
        "drums": (15, "Drums"),
        "drums 1": (16, "Drums 1"),
        "drums 2": (17, "Drums 2"),
        "aux drums": (18, "AuxDrums"),
        "drums (live)": (19, "Drums"),
        "aux drums (live)": (20, "AxDrm(Lv)"),
        "percussion": (21, "Perc"),
        "percussion 1": (22, "Perc 1"),
        "percussion 2": (23, "Perc 2"),
        "percussion 3": (24, "Perc 3"),
        "percussion 4": (25, "Perc 4"),
        "perc (live)": (26, "Perc"),
        "perc (live) 1": (27, "Perc (L1)"),
        "perc (live) 2": (28, "Perc (L2)"),
        "loop": (29, "Loop"),
        "loop 1": (30, "Loop 1"),
        "loop 2": (31, "Loop 2"),
        "loop 3": (32, "Loop 3"),
        "loop 4": (33, "Loop 4"),
        "synth loop": (34, "SynLoop"),
        "synth loop 1": (35, "SynLoop 1"),
        "synth loop 2": (36, "SynLoop 2"),
        "fx": (37, "FX"),
        "fx 1": (38, "FX 1"),
        "fx 2": (39, "FX 2"),
        "synth fx": (40, "SFX"),
        "tambourine": (41, "Tamb"),
        "tambourine 1": (42, "Tamb 1"),
        "tambourine 2": (43, "Tamb 2"),
        "suspended cymbals": (44, "Cymbals"),
        "crash cymbals": (45, "Crsh Cym"),
        "shaker": (46, "Shaker"),
        "stomps": (47, "Stomps"),
        "claps": (48, "Claps"),
        "toms": (49, "Toms"),
        "congas": (50, "Congas"),
        "bongo": (51, "Bongo"),
        "djembe": (52, "Djembe"),
        "cajon": (53, "Cajon"),
        "steel drums": (54, "SD"),
        "timbales": (55, "Timbale"),
        "chimes": (56, "Chimes"),
        "bar chimes": (57, "Bar Chime"),
        "beatbox": (58, "Beatbox"),
        "timpani": (59, "Timp"),
        "turntables": (60, "TT"),
        "snaps": (61, "Snaps"),
        "brushes": (62, "Brushes"),
        "sleigh bells": (63, "SleighBel"),
        "janggu": (64, "Janggu"),
        "gayageum": (65, "Gayageum"),
        "bass": (66, "Bass"),
        "bass 1": (67, "Bass 1"),
        "bass 2": (68, "Bass 2"),
        "synth bass": (69, "SBass"),
        "synth bass 1": (70, "SBass 1"),
        "synth bass 2": (71, "SBass 2"),
        "upright bass": (72, "Upright"),
        "acoustic guitar": (73, "AG"),
        "acoustic guitar 1": (74, "AG 1"),
        "acoustic guitar 2": (75, "AG 2"),
        "acoustic guitar 3": (76, "AG 3"),
        "acoustic guitar group": (77, "AG Group"),
        "12 strings": (78, "12 String"),
        "cuatro": (79, "Cuatro"),
        "mandolin 1": (80, "Mando 1"),
        "mandolin": (81, "Mando"),
        "mandolin 2": (82, "Mando 2"),
        "bouzouki": (83, "Bouzouk"),
        "bouzouk 1": (84, "Bouzouk 1"),
        "bouzouki 2": (85, "Bouzouk 2"),
        "dobro 1": (86, "Dobro 1"),
        "dobro 2": (87, "Dobro 2"),
        "dobro 3": (88, "Dobro 3"),
        "dulcimer": (89, "Dulcimer"),
        "dulcimer 1": (90, "Dulcim1"),
        "dulcimer 2": (91, "Dulcim2"),
        "ukulele": (92, "Ukulele"),
        "ukulele 1": (93, "Ukulele 1"),
        "ukulele 2": (94, "Ukulele 2"),
        "electric guitar 1": (95, "EG 1"),
        "electric guitar 2": (96, "EG 2"),
        "electric guitar 3": (97, "EG 3"),
        "electric guitar 4": (98, "EG 4"),
        "electric guitar 5": (99, "EG 5"),
        "electric guitar 6": (100, "EG 6"),
        "electric guitar 7": (101, "EG 7"),
        "electric guitar 8": (102, "EG 8"),
        "electric guitar 9": (103, "EG 9"),
        "electric guitar 10": (104, "EG 10"),
        "electric guitar 11": (105, "EG 11"),
        "electric guitar 12": (106, "EG 12"),
        "electric guitar group": (107, "EGs"),
        "electric guitar group 1": (108, "EGs 1"),
        "electric guitar group 2": (109, "EGs 2"),
        "electric guitar": (110, "EG"),
        "slide guitar": (111, "Slide Gtr"),
        "lap steel": (112, "Lap St"),
        "lap steel 1": (113, "Lap St 1"),
        "lap steel 2": (114, "Lap St 2"),
        "ebow": (115, "EBow"),
        "tremolo": (116, "Tremolo"),
        "guitars": (117, "Guitars"),
        "piano": (118, "Piano"),
        "piano 1": (119, "Piano 1"),
        "piano 2": (120, "Piano 2"),
        "piano 3": (121, "Piano 3"),
        "electric piano": (122, "EP"),
        "piano fx": (123, "Piano FX"),
        "cp 70": (124, "CP 70"),
        "clav": (125, "Clav"),
        "rhodes": (126, "Rhodes"),
        "mellotron": (127, "Mellotr"),
        "wurli": (128, "Wurli"),
        "organ": (129, "Organ"),
        "organ 1": (130, "Organ 1"),
        "organ 2": (131, "Organ 2"),
        "theremin": (132, "Therm"),
        "keys": (133, "Keys"),
        "keys 1": (134, "Keys 1"),
        "keys 2": (135, "Keys 2"),
        "keys 3": (136, "Keys 3"),
        "keys 4": (137, "Keys 4"),
        "keys 5": (138, "Keys 5"),
        "keys 6": (139, "Keys 6"),
        "keys 7": (140, "Keys 7"),
        "keys 8": (141, "Keys 8"),
        "keys 9": (142, "Keys 9"),
        "keys 10": (143, "Keys 10"),
        "keys group": (144, "Keys Grp"),
        "arps": (145, "Arps"),
        "arps 1": (146, "Arps 1"),
        "arps 2": (147, "Arps 2"),
        "synth lead": (148, "Synth Ld"),
        "synth strings": (149, "Synth Str"),
        "synth pad": (150, "Synth Pad"),
        "synth horns": (151, "Synth Hrn"),
        "synth bells": (152, "Synth Bel"),
        "synth group": (153, "Synth Grp"),
        "vocoder": (154, "Vocoder"),
        "vibes": (155, "Vibes"),
        "marimba": (156, "Marimba"),
        "glockenspiel": (157, "Glock"),
        "bells": (158, "Bells"),
        "harp": (159, "Harp"),
        "orchestra": (160, "Orch"),
        "strings": (161, "Strings"),
        "strings 1": (162, "String1"),
        "strings 2": (163, "String2"),
        "strings 3": (164, "String3"),
        "strings 4": (165, "String4"),
        "violin": (166, "Violin"),
        "violin 1": (167, "Violin 1"),
        "violin 2": (168, "Violin 2"),
        "violin 3": (169, "Violin 3"),
        "viola": (170, "Viola"),
        "viola 1": (171, "Viola 1"),
        "viola 2": (172, "Viola 2"),
        "viola 3": (173, "Viola 3"),
        "cello": (174, "Cello"),
        "cello 1": (175, "Cello 1"),
        "cello 2": (176, "Cello 2"),
        "cello 3": (177, "Cello 3"),
        "double bass": (178, "Dbl Bass"),
        "double bass 1": (179, "Dbl Bass 1"),
        "double bass 2": (180, "Dbl Bass 2"),
        "double bass 3": (181, "Dbl Bass 3"),
        "fiddle": (182, "Fiddle"),
        "horns": (183, "Horns"),
        "horns 1": (184, "Horns 1"),
        "horns 2": (185, "Horns 2"),
        "brass": (186, "Brass"),
        "trumpet": (187, "Trumpet"),
        "trumpet 1": (188, "Trumpet 1"),
        "trumpet 2": (189, "Trumpet 2"),
        "trumpet 3": (190, "Trumpet 3"),
        "saxophone": (191, "Sax"),
        "saxophone 1": (192, "Sax 1"),
        "saxophone 2": (193, "Sax 2"),
        "saxophone 3": (194, "Sax 3"),
        "french horn": (195, "Fr Hrn"),
        "french horn 1": (196, "Fr Hrn 1"),
        "french horn 2": (197, "Fr Hrn 2"),
        "french horn 3": (198, "Fr Hrn 3"),
        "trombone": (199, "Trmb"),
        "trombone 1": (200, "Trmb 1"),
        "trombone 2": (201, "Trmb 2"),
        "trombone 3": (202, "Trmb 3"),
        "tuba": (203, "Tuba"),
        "tuba 1": (204, "Tuba 1"),
        "tuba 2": (205, "Tuba 2"),
        "tuba 3": (206, "Tuba 3"),
        "woodwinds": (207, "Woodwinds"),
        "flute": (208, "Flute"),
        "flute 1": (209, "Flute 1"),
        "flute 2": (210, "Flute 2"),
        "flute 3": (211, "Flute 3"),
        "daegeum": (212, "Daegeum"),
        "piri": (213, "Piri"),
        "oboe": (214, "Oboe"),
        "clarinet": (215, "Clarinet"),
        "clarinet 1": (216, "Clar 1"),
        "clarinet 2": (217, "Clar 2"),
        "clarinet 3": (218, "Clar 3"),
        "accordion": (219, "Acord"),
        "accordion 1": (220, "Acord1"),
        "accordion 2": (221, "Acord2"),
        "banjo": (222, "Banjo"),
        "banjo 1": (223, "Banjo 1"),
        "banjo 2": (224, "Banjo 2"),
        "guiro": (225, "Guiro"),
        "harmonium": (226, "HM"),
        "sitar": (227, "Sitar"),
        "guzheng": (228, "Guzh"),
        "guzheng 1": (229, "Guzh 1"),
        "guzheng 2": (230, "Guzh 2"),
        "rubab": (231, "Rubab"),
        "lyre": (232, "Lyre"),
        "whistle": (233, "Whistle"),
        "bagpipes": (234, "Pipes"),
        "harmonica": (235, "Harmnic"),
        "vocals": (236, "Vocals"),
        "soprano": (237, "Soprano"),
        "soprano 1": (238, "Soprano 1"),
        "soprano 2": (239, "Soprano 2"),
        "alto": (240, "Alto"),
        "alto 1": (241, "Alto 1"),
        "alto 2": (242, "Alto 2"),
        "tenor": (243, "Tenor"),
        "tenor 1": (244, "Tenor 1"),
        "tenor 2": (245, "Tenor 2"),
        "tenor 3": (246, "Tenor 3"),
        "baritone": (247, "Barit"),
        "background vocals": (248, "BGVS"),
        "background vocals 1": (249, "BGVS 1"),
        "background vocals 2": (250, "BGVS 2"),
        "background vocals 3": (251, "BGVS 3"),
        "background vocals 4": (252, "BGVS 4"),
        "background vocals 5": (253, "BGVS 5"),
        "background vocals 6": (254, "BGVS 6"),
        "choir": (255, "Choir"),
        "choir 1": (256, "Choir 1"),
        "choir 2": (257, "Choir 2"),
        "choir 3": (258, "Choir 3"),
        "kids": (259, "Kids"),
        "oohs": (260, "Oohs"),
        "oohs 1": (261, "Oohs 1"),
        "oohs 2": (262, "Oohs 2"),
        "oohs 3": (263, "Oohs 3"),
        "background vocals fx": (264, "BGVS FX"),
        "background vocals fx 1": (265, "BgvsFx1"),
        "background vocals fx 2": (266, "BgvsFx2"),
        "background vocals fx 3": (267, "BgvsFx3"),
        "background vocals fx 4": (268, "BgvsFx4"),
        "vocal loop": (269, "VoxLoop"),
        "vocal fx": (270, "Vox FX"),
        "voxchop": (271, "VoxChop"),
        "spoken word": (272, "Spoken Wo"),
        "lead vocal": (273, "LV"),
        "lead vocal 1": (274, "LV 1"),
        "lead vocal 2": (275, "LV 2"),
        "lead vocal 3": (276, "LV 3"),
        "band": (277, "Bnd"),
        "master": (278, "Master"),
        "stereo click + tracks": (279, "SC"),
        "left": (280, "Left"),
        "right": (281, "Right"),
        "tracks": (282, "Tracks"),
        "original song": (283, "Original"),
        "midi out": (284, "MIDI Out"),
        "lead sheet": (286, "Ld Sheet"),
        "full score": (287, "Full Scr"),
        "rhythm": (288, "Rhythm")
    ]

    private static func normalizedTrackLookupKey(_ trackName: String) -> String {
        trackName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Returns Playback's canonical sort order for a track, falling back to `StemCategory` order * 1000.
    public static func playbackOrder(for trackName: String, role: TrackRole? = nil) -> Int {
        if role == .click { return 1 }
        if role == .guide { return 12 }
        let key = normalizedTrackLookupKey(trackName)
        if let entry = playbackTrackTable[key] {
            return entry.order
        }
        return category(for: trackName, role: role).rawValue * 1000
    }

    /// Returns Playback's shortened track name for narrow mixer strips & menus (e.g. `Electric Guitar 1` -> `EG 1`, `Acoustic Guitar` -> `AG`).
    public static func abbreviatedName(for trackName: String, role: TrackRole? = nil) -> String {
        if role == .click { return "Click" }
        if role == .guide { return "Guide" }
        let trimmed = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trackName }

        let key = normalizedTrackLookupKey(trimmed)
        if let entry = playbackTrackTable[key] {
            return entry.abbr
        }

        // Pattern-based shortening for numbered/variant names not verbatim in the table
        let replacements: [(pattern: String, template: String)] = [
            (#"(?i)^electric\s+guitars?\s+group(\s*\d+)?$"#, "EGs$1"),
            (#"(?i)^electric\s+guitars?(\s*\d+)?$"#, "EG$1"),
            (#"(?i)^elec\.?\s+guitars?(\s*\d+)?$"#, "EG$1"),
            (#"(?i)^acoustic\s+guitars?\s+group$"#, "AG Group"),
            (#"(?i)^acoustic\s+guitars?(\s*\d+)?$"#, "AG$1"),
            (#"(?i)^ac\.?\s+guitars?(\s*\d+)?$"#, "AG$1"),
            (#"(?i)^background\s+vocals?\s+fx(\s*\d+)?$"#, "BGVS FX$1"),
            (#"(?i)^background\s+vocals?(\s*\d+)?$"#, "BGVS$1"),
            (#"(?i)^lead\s+vocals?(\s*\d+)?$"#, "LV$1"),
            (#"(?i)^synth\s+bass(\s*\d+)?$"#, "SBass$1"),
            (#"(?i)^electric\s+piano(\s*\d+)?$"#, "EP$1"),
            (#"(?i)^percussion(\s*\d+)?$"#, "Perc$1"),
            (#"(?i)^tambourine(\s*\d+)?$"#, "Tamb$1"),
            (#"(?i)^saxophone(\s*\d+)?$"#, "Sax$1"),
            (#"(?i)^trombone(\s*\d+)?$"#, "Trmb$1"),
            (#"(?i)^french\s+horn(\s*\d+)?$"#, "Fr Hrn$1"),
            (#"(?i)^mandolin(\s*\d+)?$"#, "Mando$1"),
            (#"(?i)^double\s+bass(\s*\d+)?$"#, "Dbl Bass$1"),
            (#"(?i)^synth\s+strings(\s*\d+)?$"#, "Synth Str$1"),
            (#"(?i)^synth\s+lead(\s*\d+)?$"#, "Synth Ld$1"),
            (#"(?i)^synth\s+horns?(\s*\d+)?$"#, "Synth Hrn$1"),
            (#"(?i)^synth\s+bells?(\s*\d+)?$"#, "Synth Bel$1"),
            (#"(?i)^synth\s+loop(\s*\d+)?$"#, "SynLoop$1"),
            (#"(?i)^glockenspiel(\s*\d+)?$"#, "Glock$1")
        ]

        for rule in replacements {
            if let regex = try? NSRegularExpression(pattern: rule.pattern),
               let match = regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
               match.range.location == 0 {
                return regex.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: rule.template)
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return trimmed
    }
}
