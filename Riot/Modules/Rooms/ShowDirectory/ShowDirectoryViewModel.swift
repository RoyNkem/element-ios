// File created from ScreenTemplate
// $ createScreen.sh Rooms/ShowDirectory ShowDirectory
/*
 Copyright 2020 New Vector Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import Foundation

enum ShowDirectorySection {
    case searchInput(_ searchInputViewData: DirectoryRoomTableViewCellVM)
    case publicRoomsDirectory(_ viewModel: PublicRoomsDirectoryViewModel)
}

final class ShowDirectoryViewModel: NSObject, ShowDirectoryViewModelType {
    
    // MARK: - Properties
    
    // MARK: Private

    private let session: MXSession
    private let dataSource: PublicRoomsDirectoryDataSource
    
    private let publicRoomsDirectoryViewModel: PublicRoomsDirectoryViewModel
    
    private var currentOperation: MXHTTPOperation?
    private var sections: [ShowDirectorySection] = []
    
    private var canPaginatePublicRoomsDirectory: Bool {
        return !dataSource.hasReachedPaginationEnd && currentOperation == nil
    }
    
    private var publicRoomsDirectorySection: ShowDirectorySection {
        return .publicRoomsDirectory(self.publicRoomsDirectoryViewModel)
    }
    
    // MARK: Public

    weak var viewDelegate: ShowDirectoryViewModelViewDelegate?
    weak var coordinatorDelegate: ShowDirectoryViewModelCoordinatorDelegate?
    
    // MARK: - Setup
    
    init(session: MXSession, dataSource: PublicRoomsDirectoryDataSource) {
        self.session = session
        self.dataSource = dataSource
        self.publicRoomsDirectoryViewModel = PublicRoomsDirectoryViewModel(dataSource: dataSource, session: session)
    }
    
    deinit {
        self.cancelOperations()
    }
    
    // MARK: - Public
    
    func process(viewAction: ShowDirectoryViewAction) {
        switch viewAction {
        case .loadData:
            self.resetSections()
            self.paginatePublicRoomsDirectory(force: false)
        case .selectRoom(let indexPath):
            
            let directorySection = self.sections[indexPath.section]
            
            switch directorySection {
            case .searchInput:
                break
            case.publicRoomsDirectory:
                guard let publicRoom = dataSource.room(at: indexPath) else { return }
                self.coordinatorDelegate?.showDirectoryViewModelDidSelect(self, room: publicRoom)
            }
        case .joinRoom(let indexPath):
            
            let directorySection = self.sections[indexPath.section]
            let roomIdOrAlias: String?
            
            switch directorySection {
            case .searchInput(let searchInputViewData):
                roomIdOrAlias = searchInputViewData.title
            case .publicRoomsDirectory:
                let publicRoom = dataSource.room(at: IndexPath(row: indexPath.row, section: 0))
                roomIdOrAlias = publicRoom?.roomId
            }
            
            if let roomIdOrAlias = roomIdOrAlias {
                joinRoom(withRoomIdOrAlias: roomIdOrAlias)
            }
        case .search(let pattern):
            self.search(with: pattern)
        case .createNewRoom:
            self.coordinatorDelegate?.showDirectoryViewModelDidTapCreateNewRoom(self)
        case .switchServer:
            self.switchServer()
        case .cancel:
            self.cancelOperations()
            self.coordinatorDelegate?.showDirectoryViewModelDidCancel(self)
        }
    }
    
    func updatePublicRoomsDataSource(with cellData: MXKDirectoryServerCellDataStoring) {
        if let thirdpartyProtocolInstance = cellData.thirdPartyProtocolInstance {
            self.dataSource.thirdpartyProtocolInstance = thirdpartyProtocolInstance
        } else if let homeserver = cellData.homeserver {
            self.dataSource.includeAllNetworks = cellData.includeAllNetworks
            self.dataSource.homeserver = homeserver
        }
        
        self.resetSections()
        self.paginatePublicRoomsDirectory(force: false)
    }
    
    // MARK: - Private
    
    private func paginatePublicRoomsDirectory(force: Bool) {
        if !force && !self.canPaginatePublicRoomsDirectory {
            // We got all public rooms or we are already paginating
            // Do nothing
            return
        }
        
        self.update(viewState: .loading)
        
        // Useful only when force is true
        self.cancelOperations()
        
        currentOperation = dataSource.paginate({ [weak self] (roomsAdded) in
            guard let self = self else { return }
            if roomsAdded > 0 {
                self.update(viewState: .loaded(self.sections))
            } else {
                self.update(viewState: .loadedWithoutUpdate)
            }
            self.currentOperation = nil
        }, failure: { [weak self] (error) in
            guard let self = self else { return }
            guard let error = error else { return }
            self.update(viewState: .error(error))
            self.currentOperation = nil
        })
    }
    
    private func resetSections() {
        self.sections = [self.publicRoomsDirectorySection]
    }
    
    // FIXME: DirectoryServerPickerViewController should be instantiated from ShowDirectoryCoordinator
    // It should be just a call like: self.coordinatorDelegate?.showDirectoryServerPicker(self)
    private func switchServer() {
        let controller = DirectoryServerPickerViewController()
        let source = MXKDirectoryServersDataSource(matrixSession: session)
        source?.finalizeInitialization()
        source?.roomDirectoryServers = BuildSettings.publicRoomsDirectoryServers

        controller.display(with: source) { [weak self] (cellData) in
            guard let self = self else { return }
            guard let cellData = cellData else { return }

            self.updatePublicRoomsDataSource(with: cellData)
        }

        self.coordinatorDelegate?.showDirectoryViewModelWantsToShow(self, controller: controller)
    }
    
    private func joinRoom(withRoomIdOrAlias roomIdOrAlias: String) {
        session.joinRoom(roomIdOrAlias) { [weak self] (response) in
            guard let self = self else { return }
            switch response {
            case .success:
                self.update(viewState: .loaded(self.sections))
            case .failure(let error):
                self.update(viewState: .error(error))
            }
        }
    }
    
    private func search(with pattern: String?) {
        self.dataSource.searchPattern = pattern
        
        var sections: [ShowDirectorySection] = []
        
        var shouldUpdate = false
                
        // If the search text is a room id or alias we add search input entry in sections
        if let searchText = pattern, let searchInputViewData = self.searchInputViewData(from: searchText) {
            sections.append(.searchInput(searchInputViewData))
            
            shouldUpdate = true
        }
        
        sections.append(self.publicRoomsDirectorySection)
        
        self.sections = sections
        
        if shouldUpdate {
            self.update(viewState: .loaded(self.sections))
        }
        
        self.paginatePublicRoomsDirectory(force: true)
    }
    
    private func searchInputViewData(from searchText: String) -> DirectoryRoomTableViewCellVM? {
        guard MXTools.isMatrixRoomAlias(searchText) || MXTools.isMatrixRoomIdentifier(searchText) else {
            return nil
        }
        
        let roomIdOrAlias = searchText
        
        let searchInputViewData: DirectoryRoomTableViewCellVM
        
        if let room = self.session.vc_room(withIdOrAlias: roomIdOrAlias) {
            searchInputViewData = self.roomCellViewModel(with: room)
        } else {
            searchInputViewData = self.roomCellViewModel(with: roomIdOrAlias)
        }
        
        return searchInputViewData
    }
    
    private func roomCellViewModel(with room: MXRoom) -> DirectoryRoomTableViewCellVM {
        let displayName = room.summary.displayname
        let joinedMembersCount = Int(room.summary.membersCount.joined)
        let topic = MXTools.stripNewlineCharacters(room.summary.topic)
        let isJoined = room.summary.membership == .join
        let avatarStringUrl = room.summary.avatar
        let mediaManager = self.session.mediaManager
        
        return DirectoryRoomTableViewCellVM(title: displayName, numberOfUsers: joinedMembersCount, subtitle: topic, isJoined: isJoined, roomId: room.roomId, avatarUrl: avatarStringUrl, mediaManager: mediaManager)
    }
    
    private func roomCellViewModel(with roomIdOrAlias: String) -> DirectoryRoomTableViewCellVM {
        let displayName = roomIdOrAlias
        let mediaManager = self.session.mediaManager
        
        return DirectoryRoomTableViewCellVM(title: displayName, numberOfUsers: 0, subtitle: nil, isJoined: false, roomId: roomIdOrAlias, avatarUrl: nil, mediaManager: mediaManager)
    }
    
    private func update(viewState: ShowDirectoryViewState) {
        self.viewDelegate?.showDirectoryViewModel(self, didUpdateViewState: viewState)
    }
    
    private func cancelOperations() {
        self.currentOperation?.cancel()
    }
}

// MARK: - MXKDataSourceDelegate

extension ShowDirectoryViewModel: MXKDataSourceDelegate {
    
    func cellViewClass(for cellData: MXKCellData!) -> MXKCellRendering.Type! {
        return nil
    }
    
    func cellReuseIdentifier(for cellData: MXKCellData!) -> String! {
        return nil
    }
    
    func dataSource(_ dataSource: MXKDataSource!, didCellChange changes: Any!) {
        
    }
    
    func dataSource(_ dataSource: MXKDataSource!, didStateChange state: MXKDataSourceState) {
        self.update(viewState: .loaded(self.sections))
    }
    
}
