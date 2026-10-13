import Foundation
import Testing

@testable import BiliNextCore

@Test func liveRoomsNormalizeCanonicalIDsAndSearchImages() throws {
    let room = try #require(
        LiveParser.room(["room_id": 7_734_200, "short_id": 6, "title": "赛事", "live_status": 2]))
    #expect(room.id == 7_734_200 && !room.isLive)
    let search = try #require(
        LiveParser.room(
            [
                "roomid": "42", "title": "<em>直播</em>间", "uface": "//example.com/avatar",
                "cover": "//example.com/cover",
            ], defaultLive: true))
    #expect(search.title == "直播间" && search.avatar == "https://example.com/avatar" && search.isLive)
    #expect(LiveParser.room(["roomid": 0]) == nil)
}

private func liveFixture(format: String = "flv") -> [String: Any] {
    [
        "room_id": 42, "live_status": 1,
        "playurl_info": [
            "playurl": [
                "g_qn_desc": [
                    ["qn": 10000, "desc": "原画"], ["qn": 250, "desc": "超清"],
                    ["qn": 80, "desc": "流畅"],
                ],
                "stream": [
                    [
                        "format": [
                            [
                                "format_name": format,
                                "codec": [
                                    [
                                        "codec_name": "avc", "current_qn": 250,
                                        "accept_qn": [10000, 250], "base_url": "/stream.flv?",
                                        "url_info": [
                                            [
                                                "host": "https://cdn.example.com",
                                                "extra": "token=signed&qn=250",
                                            ],
                                            [
                                                "host": "https://backup.example.com",
                                                "extra": "token=backup",
                                            ],
                                        ],
                                    ]
                                ],
                            ]
                        ]
                    ]
                ],
            ]
        ],
    ]
}

@Test func livePlaybackPreservesSignedURLsAndServerQualityDowngrade() throws {
    let play = try LiveParser.playback(liveFixture())
    #expect(play.url.absoluteString == "https://cdn.example.com/stream.flv?token=signed&qn=250")
    #expect(play.backupURLs.count == 1 && play.roomID == 42)
    #expect(play.currentQuality == 250)
    #expect(play.qualities.map(\.id) == [10000, 250])
    #expect(try LiveParser.playback(liveFixture(format: "ts")).url.host == "cdn.example.com")
}

@Test func livePlaybackRejectsOfflineLockedAndMissingStreams() {
    #expect(throws: APIError.self) { try LiveParser.playback(["live_status": 0]) }
    #expect(throws: APIError.self) {
        try LiveParser.playback(["live_status": 1, "encrypted": true, "pwd_verified": false])
    }
    #expect(throws: APIError.self) { try LiveParser.playback(["live_status": 1]) }
}

@Test func followedLivesExcludeOfflineAndPreserveAnchorMetadata() {
    let rooms = LiveParser.followedRooms([
        "list": [
            [
                "roomid": 6, "title": "赛事", "uname": "关注主播", "face": "//example.com/face",
                "pic": "//example.com/cover", "live_status": 1,
            ],
            ["roomid": 7, "title": "未开播", "live_status": 0],
        ]
    ])
    #expect(rooms.count == 1 && rooms.first?.id == 6)
    #expect(rooms.first?.author == "关注主播" && rooms.first?.cover == "https://example.com/cover")
}

@Test func dynamicLiveCardsDecodeSerializedPayloadWithoutTreatingItAsVideo() async throws {
    let api = BilibiliAPI(restoreSession: false)
    let content =
        #"{"live_play_info":{"room_id":7734200,"title":"赛事直播","cover":"//example.com/cover","live_status":1,"area_name":"游戏赛事"}}"#
    let major: [String: Any] = ["live_rcmd": ["content": content]]
    let author: [String: Any] = ["name": "关注主播", "face": "//example.com/face", "mid": 42]
    let activity = try #require(
        await api.activity([
            "id_str": "123",
            "modules": ["module_author": author, "module_dynamic": ["major": major]],
        ]))
    #expect(activity.live?.id == 7_734_200 && activity.live?.isLive == true)
    #expect(activity.live?.author == "关注主播" && activity.live?.areaName == "游戏赛事")
    #expect(activity.video == nil)
    #expect(
        LiveParser.dynamicRoom(major: ["live_rcmd": ["content": "malformed"]], author: author)
            == nil)
    let ended = LiveParser.dynamicRoom(
        major: ["live": ["room_id": 8, "title": "已结束", "live_status": 0]], author: author)
    #expect(ended?.id == 8 && ended?.isLive == false)
    let forwarded = try #require(
        await api.activity([
            "id_str": "124", "modules": ["module_author": ["name": "转发者"]],
            "orig": ["modules": ["module_author": author, "module_dynamic": ["major": major]]],
        ]))
    #expect(forwarded.live?.author == "关注主播")
}

@Test func followedLivePaginationUsesServerPageSizeAndTotalPages() {
    #expect(LiveParser.hasMoreFollowedRooms(["list": [], "totalPage": 3, "pageSize": 10], page: 1))
    #expect(!LiveParser.hasMoreFollowedRooms(["list": [], "totalPage": 3], page: 3))
    #expect(!LiveParser.hasMoreFollowedRooms(["list": []], page: 1))
    #expect(LiveParser.hasMoreFollowedRooms(["list": [["roomid": 6]], "pageSize": 1], page: 1))
}
