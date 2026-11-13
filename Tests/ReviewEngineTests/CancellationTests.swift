import XCTest
@testable import ReviewEngine

/// 「取消」和「断网」必须分得开。
///
/// ★★ 这一组是 2026-09-03 那个错诊断的回归测试:
///   `URLSession` 取消时抛 `URLError.cancelled`,而 App 里
///   `catch { throw Failure.offline }` 把它当成断网,界面写「连不上网」——
///   <b>用户会去检查 WiFi,而真实原因是页面被换掉了。</b>
final class CancellationTests: XCTestCase {

    func testCancellationErrorIsCancellation() {
        XCTAssertTrue(Cancellation.isCancellation(CancellationError()))
    }

    func testURLErrorCancelledIsCancellation() {
        XCTAssertTrue(Cancellation.isCancellation(URLError(.cancelled)))
    }

    /// NSError 形态 —— 跨模块传递时常见,漏了它这条判断就只在一半情况下成立。
    func testNSErrorFormOfCancelledIsCancellation() {
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(Cancellation.isCancellation(ns))
    }

    /// ★ 真正的断网**不许**被当成取消 —— 否则会静默重试,用户永远看不到原因。
    func testRealNetworkFailuresAreNotCancellation() {
        for e in [URLError(.notConnectedToInternet), URLError(.timedOut),
                  URLError(.cannotFindHost), URLError(.networkConnectionLost)] {
            XCTAssertFalse(Cancellation.isCancellation(e), "\(e.code) 不是取消")
        }
    }

    func testUnrelatedErrorsAreNotCancellation() {
        struct Boom: Error {}
        XCTAssertFalse(Cancellation.isCancellation(Boom()))
        XCTAssertFalse(Cancellation.isCancellation(
            NSError(domain: "com.example", code: NSURLErrorCancelled)))
    }
}
