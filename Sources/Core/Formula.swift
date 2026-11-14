import Foundation

/// How a provider's meter counts tokens, as `script/fit.py` fits it to the histories. It is shipped, and
/// the app only checks it: how far an account's size varies says how well it holds.
public struct Formula: Sendable {
    /// What a token written out, written to the cache and read from it weighs beside one read new.
    let output, cacheWrite, cacheRead: Double
    /// What a model's tokens weigh beside another's, by a part of its name. A model none names weighs 1.
    let models: [String: Double]
    /// The weighed tokens in a point of the week on the basic plan, and on the plans of a multiple that
    /// do not hold that many of the basic one: what an account is taken to hold until it has shown it.
    let basic: Double
    let sizes: [Int: Double]

    public init(output: Double, cacheWrite: Double, cacheRead: Double, models: [String: Double], basic: Double, sizes: [Int: Double]) {
        (self.output, self.cacheWrite, self.cacheRead, self.models, self.basic, self.sizes) = (output, cacheWrite, cacheRead, models, basic, sizes)
    }

    func weigh(_ spend: Spend) -> Double {
        let model = spend.model.flatMap { name in models.first { name.contains($0.key) }?.value } ?? 1
        return model * (Double(spend.input) + output * Double(spend.output) + cacheWrite * Double(spend.cacheWrite) + cacheRead * Double(spend.cacheRead))
    }

    func size(of plan: Plan?) -> Double {
        let multiple = plan?.multiple ?? 1
        return sizes[multiple] ?? basic * Double(multiple)
    }
}

/// What an account's week is seen to hold: the weighed tokens it answered with between one rise of the
/// week and the next, at the last rises. An account also used outside Sluice rises on fewer, which the
/// median passes over unless most of its rises are so.
struct Sizing: Codable, Equatable {
    /// The week as it read at its last rise.
    private var from: Window?
    /// What it has answered with since: the weighed tokens, and in how many answers.
    private var weighed = 0.0
    private var answers = 0
    /// The weighed tokens to a point, at each of the last rises.
    private var rises: [Double] = []

    mutating func answered(weighing tokens: Double) {
        weighed += tokens
        answers += 1
    }

    /// The week now reads `budget`. Risen within the same week, what was answered since is what those
    /// points cost, unless too little was answered to have raised it. A new week, or one given back,
    /// starts the count over.
    mutating func read(_ budget: Window) {
        guard let from, from.settled.resetsAt == budget.settled.resetsAt, budget.used >= from.used else { return start(at: budget) }
        let points = ((budget.used - from.used) * 100).rounded()
        guard points >= 1 else { return }
        if answers >= 3 { rises = (rises + [weighed / points]).suffix(30) }
        start(at: budget)
    }

    private mutating func start(at budget: Window) {
        (from, weighed, answers) = (budget, 0, 0)
    }

    /// The weighed tokens in a point of its week; nil until ten rises were seen.
    var size: Double? { rises.count >= 10 ? rises.sorted()[rises.count / 2] : nil }

    /// How far that varies from rise to rise, as a share of it: half the width of the middle half.
    var spread: Double? {
        size.map { size in
            let sorted = rises.sorted()
            return (sorted[sorted.count * 3 / 4] - sorted[sorted.count / 4]) / 2 / size
        }
    }
}
