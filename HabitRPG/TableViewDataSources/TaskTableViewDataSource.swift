//
//  ReactiveTableViewDataSource.swift
//  Habitica
//
//  Created by Phillip Thelen on 05.03.18.
//  Copyright © 2018 HabitRPG Inc. All rights reserved.
//

import UIKit
import Habitica_Models
import ReactiveSwift
import Crashlytics
import Habitica_Database

@objc
public protocol TaskTableViewDataSourceProtocol {
    @objc var userDrivenDataUpdate: Bool { get set }
    @objc weak var tableView: UITableView? { get set }
    @objc var predicate: NSPredicate { get set }
    @objc var sortKey: String { get set }
    @objc var emptyDelegate: DataSourceEmptyDelegate? { get set }
    @objc var isEmpty: Bool { get set }
    
    @objc var tasks: [TaskProtocol] { get set }
    @objc var taskToEdit: TaskProtocol? { get set }
    
    @objc
    func task(at indexPath: IndexPath) -> TaskProtocol?
    @objc
    func idForObject(at indexPath: IndexPath) -> String?
    @objc
    func retrieveData(completed: (() -> Void)?)
    @objc
    func selectRowAt(indexPath: IndexPath)
    @objc
    func fixTaskOrder(movedTask: TaskProtocol, toPosition: Int)
    @objc
    func moveTask(task: TaskProtocol, toPosition: Int, completion: @escaping () -> Void)
    @objc
    func clearCompletedTodos()
    @objc
    func fetchCompletedTodos()
    
    @objc
    func predicates(filterType: Int) -> [NSPredicate]
}

class TaskTableViewDataSource: BaseReactiveTableViewDataSource<TaskProtocol>, TaskTableViewDataSourceProtocol {
    
    var onOpenForm: ((IndexPath) -> Void)?
    
    var taskType: TaskType
    var tasks: [TaskProtocol] {
        get {
            return sections[0].items
        }
        set {
            sections[0].items = newValue
        }
    }
    
    func task(at indexPath: IndexPath) -> TaskProtocol? {
        return item(at: indexPath)
    }
    
    var predicate: NSPredicate {
        didSet {
            fetchTasks()
        }
    }
    var sortKey: String = "order" {
        didSet {
            fetchTasks()
        }
    }
    
    override func didSetTableView() {
        tableView?.reloadData()
    }
    
    internal let userRepository = UserRepository()
    internal let repository = TaskRepository()
    internal let socialRepository = SocialRepository()
    
    @objc var taskToEdit: TaskProtocol?
    private var expandedIndexPath: IndexPath?
    private var fetchTasksDisposable: Disposable?
    
    init(predicate: NSPredicate, taskType: TaskType) {
        self.predicate = predicate
        self.taskType = taskType
        super.init()
        sections.append(ItemSection<TaskProtocol>())
    }
    
    override func retrieveData(completed: (() -> Void)?) {
        disposable.add(userRepository.retrieveUser().observeCompleted {
            if let action = completed {
                action()
            }
        })
    }
    
    private func fetchTasks() {
        if let disposable = fetchTasksDisposable, !disposable.isDisposed {
            disposable.dispose()
        }
        fetchTasksDisposable = repository.getTasks(predicate: predicate, sortKey: sortKey).on(failed: {[weak self] error in
                Crashlytics.sharedInstance().recordError(error)
                self?.fetchTasks()
            }, value: {[weak self] (tasks, changes) in
                self?.sections[0].items = tasks
                self?.notify(changes: changes)
        }).start()
    }

    @objc
    func idForObject(at indexPath: IndexPath) -> String? {
        return item(at: indexPath)?.id
    }
    
    @objc
    func clearCompletedTodos() {
        repository.clearCompletedTodos().observeCompleted {}
    }
    
    @objc
    func fetchCompletedTodos() {
        repository.retrieveCompletedTodos().observeCompleted {}
    }
    
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            if let task = self.item(at: indexPath) {
                if task.isChallengeTask {
                    if task.challengeBroken == nil {
                        showChallengeTaskDeleteDialog(task: task)
                    } else {
                        showBrokenChallengeDialog(task: task)
                    }
                    return
                }
                repository.deleteTask(task).observeCompleted {
                    self.fetchTasks()
                }
            }
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        if let taskCell = cell as? TaskTableViewCell, let task = item(at: indexPath) {
            configure(cell: taskCell, indexPath: indexPath, task: task)
        }
        return cell
    }
    
    func configure(cell: TaskTableViewCell, indexPath: IndexPath, task: TaskProtocol) {
        if !task.isValid {
            return
        }
        if let checkedCell = cell as? CheckedTableViewCell {
            checkedCell.isExpanded = self.expandedIndexPath?.item == indexPath.item
        }
        cell.configure(task: task)
        cell.syncErrorTouched = {[weak self] in
            let alertController = HabiticaAlertController(title: L10n.Errors.sync, message: L10n.Errors.syncMessage)
            alertController.addAction(title: L10n.resyncTask, style: .default, isMainAction: false, handler: {[weak self] (_) in
                self?.repository.syncTask(task).observeCompleted {}
            })
            alertController.addCancelAction()
            alertController.show()
        }
        cell.openForm = {[weak self] in
            if let action = self?.onOpenForm {
                action(indexPath)
            }
        }
        
        cell.challengeIconTapped = {[weak self] in
            self?.showBrokenChallengeDialog(task: task)
        }
    }
    
    internal func expandSelectedCell(indexPath: IndexPath) {
        var expandedPath = expandedIndexPath
        if tableView?.numberOfRows(inSection: 0) ?? 0 < (expandedPath?.item ?? 0) {
            expandedPath = nil
        }
        if item(at: indexPath) == nil || (expandedPath != nil && item(at: expandedPath) == nil) {
            return
        }
        self.expandedIndexPath = indexPath
        if expandedPath == nil || indexPath.item == expandedPath?.item {
            if expandedPath?.item == expandedIndexPath?.item {
                expandedIndexPath = nil
            }
            tableView?.beginUpdates()
            tableView?.reloadRows(at: [indexPath], with: .none)
            tableView?.endUpdates()
        } else {
            if let path = expandedPath {
                tableView?.beginUpdates()
                tableView?.reloadRows(at: [indexPath, path], with: .none)
                tableView?.endUpdates()
            }
        }
    }
    
    @objc
    func selectRowAt(indexPath: IndexPath) {
        taskToEdit = item(at: indexPath)
    }
    
    @objc
    func fixTaskOrder(movedTask: TaskProtocol, toPosition: Int) {
        repository.fixTaskOrder(movedTask: movedTask, toPosition: toPosition)
    }
    
    @objc
    func moveTask(task: TaskProtocol, toPosition: Int, completion: @escaping () -> Void) {
        repository.moveTask(task, toPosition: toPosition).observeCompleted {
            completion()
        }
    }
    
    func predicates(filterType: Int) -> [NSPredicate] {
        var predicates = [NSPredicate]()
        predicates.append(NSPredicate(format: "type == %@", taskType.rawValue))
        return predicates
    }
    
    internal func scoreTask(task: TaskProtocol, direction: TaskScoringDirection, soundEffect: SoundEffect) {
        disposable.add(repository.score(task: task, direction: direction)
            .on(value: {[weak self] response in
                if response?.temp?.drop?.key != nil {
                    self?.disposable.add(self?.userRepository.retrieveUser().observeCompleted {})
                }
            })
            .observeCompleted {
                SoundManager.shared.play(effect: soundEffect)
            })
    }
    
    private func showChallengeTaskDeleteDialog(task: TaskProtocol) {
        socialRepository.getChallenge(challengeID: task.challengeID ?? "", retrieveIfNotFound: true).take(first: 1).combineLatest(with:
            repository.getChallengeTasks(id: task.challengeID ?? "").take(first: 1).flatMapError({ (_) -> SignalProducer<ReactiveResults<[TaskProtocol]>, Never> in
                return SignalProducer.empty
            })).on(
            value: { (challenge, tasks) in
                let taskCount = tasks.value.count
                let alert = HabiticaAlertController(title: L10n.deleteChallengeTask, message: L10n.deleteChallengeTaskDescription(taskCount, challenge?.name ?? "" ))
                alert.addAction(title: L10n.leaveAndDeleteTask, style: .destructive, isMainAction: true, handler: { _ in
                    self.socialRepository.leaveChallenge(challengeID: task.challengeID ?? "", keepTasks: true)
                        .flatMap(.latest) { _ in
                            return self.repository.deleteTask(task)
                    }
                    .flatMap(.latest) { _ in
                        return self.repository.retrieveTasks()
                    }.observeCompleted {}
                })
                alert.addAction(title: L10n.leaveAndDeleteXTasks(taskCount), style: .destructive, isMainAction: false, handler: { _ in
                    self.socialRepository.leaveChallenge(challengeID: task.challengeID ?? "", keepTasks: false)
                    .flatMap(.latest) { _ in
                        return self.repository.retrieveTasks()
                    }.observeCompleted {}
                })
                alert.setCloseAction(title: L10n.close, handler: {})
                alert.show()
        }
        ).start()
    }
    
    private func showBrokenChallengeDialog(task: TaskProtocol) {
        repository.getChallengeTasks(id: task.challengeID ?? "").take(first: 1).on(value: { tasks in
            let taskCount = tasks.value.count
            let alert = HabiticaAlertController(title: L10n.brokenChallenge, message: L10n.brokenChallengeDescription(taskCount))
            alert.addAction(title: L10n.keepXTasks(taskCount), style: .default, isMainAction: true) { _ in
                self.repository.unlinkAllTasks(challengeID: task.challengeID ?? "", keepOption: "keep-all").observeCompleted {}
            }
            alert.addAction(title: L10n.deleteXTasks(taskCount), style: .destructive) { _ in
                self.repository.unlinkAllTasks(challengeID: task.challengeID ?? "", keepOption: "remove-all").observeCompleted {}
            }
            alert.setCloseAction(title: L10n.close, handler: {})
            alert.show()
            }).start()
    }
}
