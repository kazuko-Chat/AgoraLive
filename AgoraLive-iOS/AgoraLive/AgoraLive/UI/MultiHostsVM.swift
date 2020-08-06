//
//  MultiHostsVM.swift
//  AgoraLive
//
//  Created by CavanSu on 2020/7/22.
//  Copyright © 2020 Agora. All rights reserved.
//

import UIKit
import RxSwift
import RxRelay
import AlamoClient

class MultiHostsVM: RxObject {
    struct Invitation: TimestampModel {
        var id: Int
        var seatIndex: Int
        var initiator: LiveRole
        var receiver: LiveRole
        var timestamp: TimeInterval
        
        init(id: Int, seatIndex: Int, initiator: LiveRole, receiver: LiveRole) {
            self.id = id
            self.seatIndex = seatIndex
            self.initiator = initiator
            self.receiver = receiver
            self.timestamp = NSDate().timeIntervalSince1970
        }
    }
    
    struct Application: TimestampModel {
        var id: Int
        var seatIndex: Int
        var initiator: LiveRole
        var receiver: LiveRole
        var timestamp: TimeInterval
        
        init(id: Int, seatIndex: Int, initiator: LiveRole, receiver: LiveRole) {
            self.id = id
            self.seatIndex = seatIndex
            self.initiator = initiator
            self.receiver = receiver
            self.timestamp = NSDate().timeIntervalSince1970
        }
    }
    
    private var room: Room
    
    let invitationQueue = TimestampQueue(name: "multi-hosts-invitation")
    let applicationQueue = TimestampQueue(name: "multi-hosts-application")
    
    let invitingUserList = BehaviorRelay(value: [LiveRole]())
    let applyingUserList = BehaviorRelay(value: [LiveRole]())
     
    // Owner
    var invitationByRejected = PublishRelay<Invitation>()
    var invitationByAccepted = PublishRelay<Invitation>()
    var receivedApplication = PublishRelay<Application>()
    
    // Broadcaster
    var receivedEndBroadcasting = PublishRelay<()>()
    
    // Audience
    var receivedInvitation = PublishRelay<Invitation>()
    var applicationByRejected = PublishRelay<Application>()
    var applicationByAccepted = PublishRelay<Application>()
    
    //
    var audienceBecameBroadcaster = PublishRelay<LiveRole>()
    var broadcasterBecameAudience = PublishRelay<LiveRole>()
    
    init(room: Room) {
        self.room = room
        super.init()
        observe()
    }
    
    deinit {
        let rtm = ALCenter.shared().centerProvideRTMHelper()
        rtm.removeReceivedChannelMessage(observer: self)
    }
}

// MARK: Owner
extension MultiHostsVM {
    func sendInvitation(to user: LiveRole, on seatIndex: Int, fail: ErrorCompletion = nil) {
        request(seatIndex: seatIndex,
                type: 1,
                userId: "\(user.info.userId)",
                roomId: room.roomId,
                success: { [weak self] (json) in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    let id = try json.getIntValue(of: "data")
                    let invitation = Invitation(id: id,
                                                seatIndex: seatIndex,
                                                initiator: strongSelf.room.owner,
                                                receiver: user)
                    strongSelf.invitationQueue.append(invitation)
                }, fail: fail)
    }
    
    func accept(application: Application, fail: ErrorCompletion = nil) {
        request(seatIndex: application.seatIndex,
                type: 5,
                userId: "\(application.initiator.info.userId)",
                roomId: room.roomId,
                success: { [weak self] (json) in
                    self?.applicationQueue.remove(application)
                }, fail: fail)
                
    }
    
    func reject(application: Application, fail: ErrorCompletion = nil) {
        request(seatIndex: application.seatIndex,
                type: 3,
                userId: "\(application.initiator.info.userId)",
                roomId: room.roomId,
                success: { [weak self] (json) in
                    self?.applicationQueue.remove(application)
                }, fail: fail)
    }
    
    func forceEndBroadcasting(user: LiveRole, on seatIndex: Int, success: Completion = nil, fail: ErrorCompletion = nil) {
        request(seatIndex: seatIndex,
                type: 7,
                userId: "\(user.info.userId)",
                roomId: room.roomId,
                success: { (_) in
                    if let success = success {
                        success()
                    }
                }, fail: fail)
    }
}

// MARK: Broadcaster
extension MultiHostsVM {
    func endBroadcasting(seatIndex: Int, user: LiveRole, fail: ErrorCompletion = nil) {
        request(seatIndex: seatIndex,
                type: 8,
                userId: "\(user.info.userId)",
                roomId: room.roomId,
                fail: fail)
    }
}

// MARK: Audience
extension MultiHostsVM {
    func sendApplication(by local: LiveRole, for seatIndex: Int, fail: ErrorCompletion = nil) {
        request(seatIndex: seatIndex,
                type: 2,
                userId: "\(room.owner.info.userId)",
                roomId: room.roomId,
                fail: fail)
    }
    
    func accept(invitation: Invitation, success: Completion = nil, fail: ErrorCompletion = nil) {
        request(seatIndex: invitation.seatIndex,
                type: 6,
                userId: "\(invitation.initiator.info.userId)",
                roomId: room.roomId,
                fail: fail)
    }
    
    func reject(invitation: Invitation, fail: ErrorCompletion = nil) {
        request(seatIndex: invitation.seatIndex,
                type: 4,
                userId: "\(invitation.initiator.info.userId)",
                roomId: room.roomId,
                fail: fail)
    }
}

private extension MultiHostsVM {
    // type: 1.房主邀请 2.观众申请 3.房主拒绝 4.观众拒绝 5.房主同意观众申请 6.观众接受房主邀请 7.房主让主播下麦 8.主播下麦
    func request(seatIndex: Int, type: Int, userId: String, roomId: String, success: DicEXCompletion = nil, fail: ErrorCompletion) {
        let client = ALCenter.shared().centerProvideRequestHelper()
        let task = RequestTask(event: RequestEvent(name: "multi-action: \(type)"),
                               type: .http(.post, url: URLGroup.multiHosts(userId: userId, roomId: roomId)),
                               timeout: .medium,
                               header: ["token": ALKeys.ALUserToken],
                               parameters: ["no": seatIndex, "type": type])
        client.request(task: task, success: ACResponse.json({ (json) in
            if let success = success {
                try success(json)
            }
        })) { (error) -> RetryOptions in
            if let fail = fail {
                fail(error)
            }
            return .resign
        }
    }
    
    func observe() {
        let rtm = ALCenter.shared().centerProvideRTMHelper()
        
        rtm.addReceivedPeerMessage(observer: self) { [weak self] (json) in
            guard let cmd = try? json.getEnum(of: "cmd", type: ALPeerMessage.AType.self),
                cmd == .multiHosts,
                let strongSelf = self else {
                return
            }
            
            let data = try json.getDataObject()
            
            let type = try data.getIntValue(of: "type")
            let seatIndex = try data.getIntValue(of: "no")
            let id = try data.getIntValue(of: "processId")
            let userJson = try data.getDictionaryValue(of: "fromUser")
            let role = try LiveRoleItem(dic: userJson)
            
            guard let local = ALCenter.shared().liveSession?.role else {
                return
            }
            
            switch type {
            // Owner
            case  2: // receivedApplication:
                let application = Application(id: id, seatIndex: seatIndex, initiator: role, receiver: local)
                strongSelf.receivedApplication.accept(application)
            case  4: // audience rejected invitation
                let invitation = Invitation(id: id, seatIndex: seatIndex, initiator: local, receiver: role)
                strongSelf.invitationByRejected.accept(invitation)
            case  6: // audience accepted invitation:
                let invitation = Invitation(id: id, seatIndex: seatIndex, initiator: local, receiver: role)
                strongSelf.invitationByAccepted.accept(invitation)
            
            // Broadcaster
            case 7: //
                strongSelf.receivedEndBroadcasting.accept(())
                
            // Audience
            case  1: // receivedInvitation
                let invitation = Invitation(id: id, seatIndex: seatIndex, initiator: role, receiver: local)
                strongSelf.receivedInvitation.accept(invitation)
            case  3: // applicationByRejected
                let application = Application(id: id, seatIndex: seatIndex, initiator: local, receiver: role)
                strongSelf.applicationByRejected.accept(application)
            case  5: // applicationByAccepted:
                let application = Application(id: id, seatIndex: seatIndex, initiator: local, receiver: role)
                strongSelf.applicationByAccepted.accept(application)
            default:
                assert(false)
                break
            }
        }
        
        rtm.addReceivedChannelMessage(observer: self) { [weak self] (json) in
            guard let cmd = try? json.getEnum(of: "cmd", type: ALChannelMessage.AType.self),
                let strongSelf = self else {
                return
            }
            
            // strongSelf.audienceBecameBroadcaster
        }
        
        // Owner
        invitationByRejected.subscribe(onNext: { [weak self] (invitaion) in
            self?.invitationQueue.remove(invitaion)
        }).disposed(by: bag)
        
        invitationByAccepted.subscribe(onNext: { [weak self] (invitaion) in
            self?.invitationQueue.remove(invitaion)
        }).disposed(by: bag)
        
        //
        invitationQueue.queueChanged.subscribe(onNext: { [unowned self] (list) in
            guard let tList = list as? [Invitation] else {
                return
            }
            
            let users = tList.map { (invitation) -> LiveRole in
                return invitation.receiver
            }
            
            self.invitingUserList.accept(users)
        }).disposed(by: bag)
        
        applicationQueue.queueChanged.subscribe(onNext: { [unowned self] (list) in
            guard let tList = list as? [Application] else {
                return
            }
            
            let users = tList.map { (invitation) -> LiveRole in
                return invitation.initiator
            }
            
            self.applyingUserList.accept(users)
        }).disposed(by: bag)
    }
}