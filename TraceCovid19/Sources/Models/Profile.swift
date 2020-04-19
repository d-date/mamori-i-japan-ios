//
//  Profile.swift
//  TraceCovid19
//
//  Created by yosawa on 2020/04/19.
//

import Foundation

struct Profile: DictionaryEncodable, DictionaryDecodable {
    private(set) var prefecture: Int?
    private(set) var job: String?

    @discardableResult
    mutating func update(prefecture: PrefectureModel) -> Profile {
        self.prefecture = prefecture.index
        return self
    }

    @discardableResult
    mutating func update(job: String?) -> Profile {
        self.job = isValidJob(job: job)
        return self
    }
}

extension Profile {
    init(prefecture: PrefectureModel, job: String?) {
        self.prefecture = prefecture.index
        self.job = isValidJob(job: job)
    }

    static let empty: Profile = {
        .init(prefecture: nil, job: nil)
    }()
}

private func isValidJob(job: String?) -> String? {
    if let job = job, !job.isEmpty {
        // 空文字は省く
        return job
    } else {
        return nil
    }
}
