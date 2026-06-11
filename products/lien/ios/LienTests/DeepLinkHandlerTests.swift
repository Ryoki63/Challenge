// DeepLinkHandlerTests.swift — 招待ディープリンクのパース(T11 / DESIGN §3.6)
//
// token の形式判定はサーバー(invite-accept/core.ts の TOKEN_FORMAT = /^[A-Za-z0-9]{8}$/)
// と同一であることをここで固定する(契約整合 — issue #11)。

import XCTest
@testable import Lien

final class DeepLinkHandlerTests: XCTestCase {
    private func token(_ string: String) -> String? {
        guard let url = URL(string: string) else {
            XCTFail("URL として解釈できない: \(string)")
            return nil
        }
        return DeepLinkHandler.inviteToken(from: url)
    }

    // MARK: 正常系

    func testParsesCustomSchemeInviteURL() {
        XCTAssertEqual(token("lien://invite/AbCd2345"), "AbCd2345")
        // 数字のみ・大文字のみも8文字英数なら通す(サーバーの TOKEN_FORMAT と同じ)
        XCTAssertEqual(token("lien://invite/23456789"), "23456789")
        XCTAssertEqual(token("lien://invite/ABCDEFGH"), "ABCDEFGH")
    }

    func testParsesWebPageURLWithTokenQuery() {
        // 静的ページ形式(DESIGN §6): https://<GH_PAGES>/lien/i/?t=<token>
        XCTAssertEqual(
            token("https://ryoki63.github.io/Challenge/lien/i/?t=AbCd2345"),
            "AbCd2345"
        )
        // 他のクエリが混ざっていても t を拾う
        XCTAssertEqual(
            token("https://example.com/lien/i/?utm=x&t=AbCd2345"),
            "AbCd2345"
        )
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(token("LIEN://invite/AbCd2345"), "AbCd2345")
    }

    // MARK: 不正 URL

    func testRejectsWrongSchemeOrHost() {
        XCTAssertNil(token("other://invite/AbCd2345"))
        XCTAssertNil(token("lien://other/AbCd2345"))
        XCTAssertNil(token("lien://invite")) // token 無し
    }

    func testRejectsExtraPathSegments() {
        XCTAssertNil(token("lien://invite/AbCd2345/extra"))
    }

    func testRejectsWrongTokenLength() {
        XCTAssertNil(token("lien://invite/AbCd234"))   // 7文字
        XCTAssertNil(token("lien://invite/AbCd23456")) // 9文字
        XCTAssertNil(token("https://example.com/lien/i/?t=AbCd234"))
    }

    func testRejectsNonAlphanumericToken() {
        XCTAssertNil(token("lien://invite/AbCd234-"))
        XCTAssertNil(token("lien://invite/AbCd_234"))
        XCTAssertNil(token("https://example.com/lien/i/?t=AbCd234%E3%81%82")) // 全角混入
    }

    func testRejectsWebURLWithoutTokenQuery() {
        XCTAssertNil(token("https://ryoki63.github.io/Challenge/lien/i/"))
        XCTAssertNil(token("https://ryoki63.github.io/Challenge/lien/i/?t="))
    }

    // MARK: InviteToken.isValidFormat(単体)

    func testInviteTokenFormatMatchesServerRegex() {
        // /^[A-Za-z0-9]{8}$/ と同じ受理・拒否(invite-accept/core.ts TOKEN_FORMAT)
        XCTAssertTrue(InviteToken.isValidFormat("AbCd2345"))
        XCTAssertTrue(InviteToken.isValidFormat("aaaaaaaa"))
        XCTAssertTrue(InviteToken.isValidFormat("00000000")) // 形式上は通す(発行側が 0 を使わないだけ)
        XCTAssertFalse(InviteToken.isValidFormat(""))
        XCTAssertFalse(InviteToken.isValidFormat("AbCd234"))
        XCTAssertFalse(InviteToken.isValidFormat("AbCd23456"))
        XCTAssertFalse(InviteToken.isValidFormat("AbCd 234"))
        XCTAssertFalse(InviteToken.isValidFormat("AbCd234あ"))
        XCTAssertFalse(InviteToken.isValidFormat("AbCd234é"))
    }
}
