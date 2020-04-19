//
//  ProfileService.swift
//  TraceCovid19
//
//  Created by yosawa on 2020/04/19.
//

import Foundation
import FirebaseFirestore
import FirebaseAuth
import Swinject

final class ProfileService {
    private let firestore: Lazy<Firestore> // Firebase.configure()の後で使用するためLazyでラップ
    private let auth: Lazy<Auth>
    init(firestore: Lazy<Firestore>, auth: Lazy<Auth>) {
        self.firestore = firestore
        self.auth = auth
    }

    func set(profile: Profile, completion: @escaping (Bool) -> Void) {
        guard let uid = auth.instance.currentUser?.uid else {
            print("[LoginService] not found uid")
            return
        }
        guard let profileData = try? profile.asDictionary() else {
            print("[LoginService] profile is invalid format: \(profile)")
            return
        }
        firestore.instance
            .collection("users")
            .document(uid)
            .collection("profile")
            .document(uid).setData(profileData) { error in
                if let err = error {
                    print("[LoginService] Error writing profile: \(err)")
                    completion(false)
                } else {
                    // [NOTE] 成功しても特にフィードバックはしない
                    print("[LoginService] Profile successfully written")
                    completion(true)
                }
            }
    }

    func get(completion: @escaping (Result<Profile, Error>) -> Void) {
        guard let uid = auth.instance.currentUser?.uid else {
            print("[LoginService] not found uid")
            completion(.failure(NSError(domain: "not found uid", code: 0, userInfo: nil)))
            return
        }
        firestore.instance
            .collection("users")
            .document(uid)
            .collection("profile")
            .document(uid).getDocument { response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let dictionary = response?.data() else {
                    // 空状態(理論上はありうるため正常系として返す)
                    completion(.success(Profile.empty))
                    return
                }

                guard let profile = try? Profile.make(dictionary: dictionary) else {
                    completion(.failure(NSError(domain: "Profile parse error", code: 0, userInfo: nil)))
                    return
                }
                completion(.success(profile))
            }
    }
}
